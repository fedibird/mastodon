# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::DispatchExecutor do # rubocop:disable Metrics/BlockLength
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
      dispatch_cohort: :operational,
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

  def steal_lease!(handle)
    FollowImportDispatchLease.find(FollowImportDispatchLease::SINGLETON_ID).update!(
      owner_token: 'newer',
      fencing_generation: handle.fencing_generation + 1,
      expires_at: 1.hour.from_now
    )
  end

  before do
    allow(Import::RelationshipWorker).to receive(:perform_async)
    allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for) do |_resolver, target|
      { acct: "acct-#{target.id}@remote.test", options: { 'show_reblogs' => true } }
    end
  end

  context 'with a current lease' do # rubocop:disable Metrics/BlockLength
    around do |example|
      FollowImport::DispatchLease.with_lease do |handle|
        @lease = handle
        example.run
      end
    end

    let(:executor) { described_class.new(lease: @lease) }

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

    it 'does not claim a historical scheduler-owned batch handed directly to the executor' do
      batch.update!(dispatch_cohort: :historical, dispatch_owner: :scheduler)
      target = add_target(0)

      result = executor.execute([entry_for(target)])

      expect(result.claimed_count).to eq 0
      expect(result.skipped_wrong_owner_count).to eq 1
      expect(target.reload.state).to eq 'pending'
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    end

    it 'does not claim a screening scheduler-owned batch' do
      batch.update!(preflight_state: :screening)
      target = add_target(0)

      result = executor.execute([entry_for(target)])

      expect(result.claimed_count).to eq 0
      expect(result.skipped_wrong_owner_count).to eq 1
      expect(target.reload.state).to eq 'pending'
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    end

    it 're-checks owner and cohort inside the claim fence' do
      target = add_target(0)
      allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for) do |_resolver, row|
        batch.update!(dispatch_cohort: :historical)
        { acct: "acct-#{row.id}@remote.test", options: { 'show_reblogs' => true } }
      end

      result = executor.execute([entry_for(target)])

      expect(result.claimed_count).to eq 0
      expect(result.skipped_wrong_owner_count).to eq 1
      expect(target.reload.state).to eq 'pending'
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    end

    it 'does not claim a stale plan after ready becomes review_required inside the fence' do
      target = add_target(0)
      allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for) do |_resolver, row|
        batch.update!(preflight_state: :review_required)
        { acct: "acct-#{row.id}@remote.test", options: { 'show_reblogs' => true } }
      end

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
  end

  describe 'lease fencing' do # rubocop:disable Metrics/BlockLength
    it 'requires a lease handle' do
      expect { described_class.new }.to raise_error(ArgumentError)
    end

    it 'does not claim when the lease handle is nil' do
      target = add_target(0)

      result = described_class.new(lease: nil).execute([entry_for(target)])

      expect(result.claimed_count).to eq 0
      expect(result.stopped).to be true
      expect(result.error_class).to eq 'FollowImport::DispatchLease::LostOwnership'
      expect(target.reload.state).to eq 'pending'
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
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

    it 'does not mark_queued after a newer generation takes ownership' do
      target = add_target(0)

      result = nil
      FollowImport::DispatchLease.with_lease do |handle|
        allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for) do |_resolver, row|
          steal_lease!(handle)
          { acct: "acct-#{row.id}@remote.test", options: {} }
        end

        result = described_class.new(lease: handle).execute([entry_for(target)])
      end

      expect(result.claimed_count).to eq 0
      expect(result.stopped).to be true
      expect(result.error_class).to eq 'FollowImport::DispatchLease::LostOwnership'
      expect(target.reload.state).to eq 'pending'
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    end

    it 'keeps already-enqueued claims when a later fencing check fails' do
      first = add_target(0)
      second = add_target(1)

      result = nil
      FollowImport::DispatchLease.with_lease do |handle|
        allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for) do |_resolver, target|
          steal_lease!(handle) if target.id == second.id
          { acct: "acct-#{target.id}@remote.test", options: {} }
        end

        result = described_class.new(lease: handle).execute([entry_for(first), entry_for(second)])
      end

      expect(result.claimed_count).to eq 1
      expect(result.stopped).to be true
      expect(result.error_class).to eq 'FollowImport::DispatchLease::LostOwnership'
      expect(first.reload.state).to eq 'queued'
      expect(second.reload.state).to eq 'pending'
      expect(Import::RelationshipWorker).to have_received(:perform_async).once
    end
  end
end
