# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::DispatchExecutor do # rubocop:disable Metrics/BlockLength
  subject(:executor) { described_class.new }

  let(:account) { Fabricate(:account) }
  let(:import_record) do
    Import.create!(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt'),
                   follow_import_pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION)
  end
  let(:batch) do
    FollowImportBatch.create!(
      subject: ModerationSubject.for_account!(account),
      import_id: import_record.id,
      imported_at: Time.now.utc,
      mode: :merge,
      dispatch_owner: :scheduler,
      target_count: 0,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
  end

  def add_target(position)
    batch.targets.create!(target_key_hash: "key-#{position}", position: position)
  end

  def entry_for(target)
    FollowImport::FairScheduler::Entry.new(
      owner_key: FollowImport::OwnerKey.for_batch(batch),
      batch_id: batch.id,
      target_id: target.id,
      position: target.position,
      destination_domain: 'remote.test'
    )
  end

  before do
    allow(Import::RelationshipWorker).to receive(:perform_async)
    allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for) do |_resolver, target|
      { acct: "acct-#{target.id}@remote.test", options: { 'show_reblogs' => true } }
    end
  end

  it 'marks a pending scheduler target queued and enqueues RelationshipWorker once' do
    target = add_target(0)

    result = executor.execute([entry_for(target)])

    expect(result.claimed_count).to eq 1
    expect(target.reload.state).to eq 'queued'
    expect(Import::RelationshipWorker).to have_received(:perform_async)
      .with(account.id, "acct-#{target.id}@remote.test", 'follow', hash_including(
                                                                     'import_batch_id' => batch.id,
                                                                     'follow_import_target_id' => target.id
                                                                   ))
  end

  it 'does not claim a legacy-owned batch' do
    batch.update!(dispatch_owner: :legacy)
    target = add_target(0)

    result = executor.execute([entry_for(target)])

    expect(result.claimed_count).to eq 0
    expect(result.skipped_wrong_owner_count).to eq 1
    expect(target.reload.state).to eq 'pending'
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
  end

  it 'leaves an unrecoverable target pending and continues' do
    first = add_target(0)
    second = add_target(1)
    allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for) do |_resolver, target|
      next if target.id == first.id

      { acct: "acct-#{target.id}@remote.test", options: {} }
    end

    result = executor.execute([entry_for(first), entry_for(second)])

    expect(result.claimed_count).to eq 1
    expect(result.skipped_unrecoverable_count).to eq 1
    expect(first.reload.state).to eq 'pending'
    expect(second.reload.state).to eq 'queued'
  end

  it 'parses one ImportUnitResolver per batch in the tick' do
    first = add_target(0)
    second = add_target(1)
    resolvers = []
    allow(FollowImport::ImportUnitResolver).to receive(:new).and_wrap_original do |method, *args|
      resolvers << method.call(*args)
      resolvers.last
    end
    allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for) do |_resolver, target|
      { acct: "acct-#{target.id}@remote.test", options: {} }
    end

    executor.execute([entry_for(first), entry_for(second)])

    expect(resolvers.size).to eq 1
  end

  it 'releases a queued claim and stops the tick when enqueue fails' do
    first = add_target(0)
    second = add_target(1)
    third = add_target(2)
    calls = 0
    allow(Import::RelationshipWorker).to receive(:perform_async) do
      calls += 1
      raise 'redis down' if calls == 2

      true
    end

    result = executor.execute([entry_for(first), entry_for(second), entry_for(third)])

    expect(result.claimed_count).to eq 1
    expect(result.stopped).to be true
    expect(result.error_class).to eq 'RuntimeError'
    expect(first.reload.state).to eq 'queued'
    expect(second.reload.state).to eq 'pending'
    expect(third.reload.state).to eq 'pending'
  end

  it 'claims when the current lease generation still owns the row' do
    target = add_target(0)

    result = nil
    FollowImport::DispatchLease.with_lease do |handle|
      result = described_class.new(lease: handle).execute([entry_for(target)])
    end

    expect(result.claimed_count).to eq 1
    expect(result.stopped).to be false
    expect(target.reload.state).to eq 'queued'
    expect(Import::RelationshipWorker).to have_received(:perform_async)
  end

  it 'does not claim when the lease handle is no longer current' do
    FollowImportDispatchLease.find(FollowImportDispatchLease::SINGLETON_ID).update!(
      owner_token: 'newer',
      fencing_generation: 2,
      expires_at: 1.hour.from_now
    )
    handle = FollowImport::DispatchLease::Handle.new(
      owner_token: 'stale',
      fencing_generation: 1,
      strategy: FollowImport::DispatchLease::STRATEGY
    )
    target = add_target(0)

    result = described_class.new(lease: handle).execute([entry_for(target)])

    expect(result.claimed_count).to eq 0
    expect(result.stopped).to be true
    expect(result.error_class).to eq 'FollowImport::DispatchLease::LostOwnership'
    expect(target.reload.state).to eq 'pending'
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
  end

  it 'keeps already-enqueued claims when a later fencing check fails' do
    first = add_target(0)
    second = add_target(1)
    handle = instance_double(FollowImport::DispatchLease::Handle)
    allow(handle).to receive(:current_owner?).and_return(true, false)

    result = described_class.new(lease: handle).execute([entry_for(first), entry_for(second)])

    expect(result.claimed_count).to eq 1
    expect(result.stopped).to be true
    expect(result.error_class).to eq 'FollowImport::DispatchLease::LostOwnership'
    expect(first.reload.state).to eq 'queued'
    expect(second.reload.state).to eq 'pending'
    expect(Import::RelationshipWorker).to have_received(:perform_async).once
  end
end
