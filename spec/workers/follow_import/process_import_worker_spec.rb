# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::ProcessImportWorker do # rubocop:disable Metrics/BlockLength
  subject(:worker) { described_class.new }

  let(:account) { Fabricate(:account) }

  def create_follow_import(overwrite: false, pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION)
    Import.create!(
      account: account,
      type: 'following',
      overwrite: overwrite,
      data: attachment_fixture('new-following-imports.txt'),
      follow_import_pipeline_version: pipeline_version
    )
  end

  before do
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
    allow(Import::RelationshipWorker).to receive(:perform_async)
  end

  it 'records a batch and hands a marked import to the executor' do
    import = create_follow_import

    worker.perform(import.id)

    batch = FollowImportBatch.find_by(import_id: import.id)
    expect(batch).to be_present
    expect(batch.legacy_dispatch_owner?).to be true
    expect(batch.ready_preflight_state?).to be true
    expect(FollowImport::BatchExecutionWorker).to have_received(:perform_async).with(batch.id)
    expect(Import.exists?(import.id)).to be true
  end

  it 'does not enqueue BatchExecutionWorker or mutate targets when retrying a historical legacy import' do
    import = create_follow_import
    batch = FollowImportBatch.create!(
      subject: ModerationSubject.for_account!(account),
      import_id: import.id,
      imported_at: Time.now.utc,
      mode: :merge,
      dispatch_owner: :legacy,
      dispatch_cohort: :historical,
      target_count: 0,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
    target = batch.targets.create!(target_key_hash: 'historical-retry', position: 0)

    worker.perform(import.id)

    expect(batch.reload.legacy_dispatch_owner?).to be true
    expect(batch.historical_dispatch_cohort?).to be true
    expect(target.reload.state).to eq 'pending'
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    expect(Import.exists?(import.id)).to be true
  end

  it 'does not release review_required on retry and retains the Import' do
    import = create_follow_import
    batch = FollowImportBatch.create!(
      subject: ModerationSubject.for_account!(account),
      import_id: import.id,
      imported_at: Time.now.utc,
      mode: :merge,
      dispatch_owner: :legacy,
      dispatch_cohort: :operational,
      preflight_state: :review_required,
      target_count: 0,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
    target = batch.targets.create!(target_key_hash: 'held-retry', position: 0)

    worker.perform(import.id)

    expect(batch.reload.review_required_preflight_state?).to be true
    expect(target.reload.state).to eq 'pending'
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    expect(Import.exists?(import.id)).to be true
  end

  it 'does not revert a ready batch on retry' do
    import = create_follow_import
    batch = FollowImportBatch.create!(
      subject: ModerationSubject.for_account!(account),
      import_id: import.id,
      imported_at: Time.now.utc,
      mode: :merge,
      dispatch_owner: :legacy,
      dispatch_cohort: :operational,
      preflight_state: :ready,
      target_count: 0,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
    batch.targets.create!(target_key_hash: 'ready-retry', position: 0)

    worker.perform(import.id)

    expect(batch.reload.ready_preflight_state?).to be true
    expect(FollowImport::BatchExecutionWorker).to have_received(:perform_async).with(batch.id)
    expect(Import.exists?(import.id)).to be true
  end

  it 'retains the Import when GLOBAL recording fails so the worker can retry' do
    import = create_follow_import
    allow(Moderation::FollowImportRecorder).to receive(:record_batch!).and_raise(ActiveRecord::StatementInvalid, 'boom')
    allow(Import::RelationshipWorker).to receive(:push_bulk)

    ClimateControl.modify FOLLOW_IMPORT_DISPATCH_GLOBAL: 'true' do
      expect { worker.perform(import.id) }.to raise_error(ActiveRecord::StatementInvalid, 'boom')
    end

    expect(Import.exists?(import.id)).to be true
    expect(FollowImportBatch.where(import_id: import.id)).to be_none
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    expect(Import::RelationshipWorker).not_to have_received(:push_bulk)
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
  end

  it 'does not enqueue BatchExecutionWorker for a new GLOBAL-owned batch' do
    import = create_follow_import

    ClimateControl.modify FOLLOW_IMPORT_DISPATCH_GLOBAL: 'true' do
      worker.perform(import.id)
    end

    batch = FollowImportBatch.find_by(import_id: import.id)
    expect(batch.scheduler_dispatch_owner?).to be true
    expect(batch.ready_preflight_state?).to be true
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    expect(Import.exists?(import.id)).to be true
  end

  it 'does not call ImportService for an unmarked leftover follow import' do
    import = create_follow_import(pipeline_version: nil)
    allow(ImportService).to receive(:new)

    worker.perform(import.id)

    expect(ImportService).not_to have_received(:new)
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    expect(FollowImportBatch.where(import_id: import.id)).to be_none
    expect(Import.exists?(import.id)).to be true
  end

  it 'does not call ImportService for an unknown pipeline version' do
    [2, 999].each do |version|
      import = create_follow_import(pipeline_version: version)
      allow(ImportService).to receive(:new)

      worker.perform(import.id)

      expect(ImportService).not_to have_received(:new)
      expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
      expect(FollowImportBatch.where(import_id: import.id)).to be_none
      expect(Import.exists?(import.id)).to be true
    end
  end

  it 'does not start follow or unfollow work when an unmarked overwrite import reaches the worker' do
    extra = Fabricate(:account, username: 'already_followed')
    account.follow!(extra)
    import = create_follow_import(overwrite: true, pipeline_version: nil)

    allow(ImportService).to receive(:new)
    allow(FollowService).to receive(:new)
    allow(UnfollowService).to receive(:new)

    worker.perform(import.id)

    expect(ImportService).not_to have_received(:new)
    expect(FollowService).not_to have_received(:new)
    expect(UnfollowService).not_to have_received(:new)
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    expect(account.following?(extra)).to be true
    expect(Import.exists?(import.id)).to be true
  end
end
