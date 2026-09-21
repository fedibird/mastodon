# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduler::FollowImportCsvCleanupScheduler do # rubocop:disable Metrics/BlockLength
  subject(:worker) { described_class.new }

  let(:account) { Fabricate(:account) }

  def import_for(account, pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION)
    Import.create!(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt'),
                   follow_import_pipeline_version: pipeline_version)
  end

  def batch_with_import(import, imported_at: Time.now.utc)
    FollowImportBatch.create!(subject: ModerationSubject.for_account!(account), import_id: import.id,
                              imported_at: imported_at, mode: :merge, target_count: 0,
                              resolved_target_count: 0, unresolved_target_count: 0)
  end

  def add_target(batch, state, position)
    batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: position, state: state)
  end

  it 'drops the import once the batch has no pending targets (dispatch complete)' do
    import = import_for(account)
    batch  = batch_with_import(import)
    add_target(batch, :accepted, 0)
    add_target(batch, :delivery_failed, 1)

    worker.perform

    expect(Import.exists?(import.id)).to be false
  end

  it 'cleans a zero-target scheduler-owned batch without a BatchExecutionWorker chain' do
    import = import_for(account)
    batch  = batch_with_import(import)
    batch.update!(dispatch_owner: :scheduler, target_count: 0)
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)

    worker.perform

    expect(Import.exists?(import.id)).to be false
    expect(FollowImportBatch.exists?(batch.id)).to be true
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
  end

  it 'leaves an import with pending targets alone regardless of age (age is not abandonment)' do
    # PR C leaves gate-deferred (delay / moderator_review) targets pending on
    # purpose; the CSV is still needed to recover their acct/options on a future
    # recheck, so an old batch with pending targets must NOT be cleaned.
    import = import_for(account)
    batch  = batch_with_import(import, imported_at: 30.days.ago)
    add_target(batch, :pending, 0)

    worker.perform

    expect(Import.exists?(import.id)).to be true
  end

  it 'leaves a recent, still-dispatching import alone (pending targets remain)' do
    import = import_for(account)
    batch  = batch_with_import(import, imported_at: 10.minutes.ago)
    add_target(batch, :queued, 0)
    add_target(batch, :pending, 1)

    worker.perform

    expect(Import.exists?(import.id)).to be true
  end

  it 'retains the Import/CSV for a non-ready batch with pending targets' do
    import = import_for(account)
    batch  = batch_with_import(import)
    batch.update!(preflight_state: :screening, dispatch_cohort: :operational)
    add_target(batch, :pending, 0)

    worker.perform

    expect(Import.exists?(import.id)).to be true
    expect(batch.reload.screening_preflight_state?).to be true
  end

  it 'is a no-op for a batch whose import is already gone' do
    batch = FollowImportBatch.create!(subject: ModerationSubject.for_account!(account), import_id: 999_999,
                                      imported_at: Time.now.utc, mode: :merge, target_count: 0,
                                      resolved_target_count: 0, unresolved_target_count: 0)
    add_target(batch, :accepted, 0)

    expect { worker.perform }.not_to raise_error
  end

  describe 'stalled follow imports (no batch recorded yet)' do
    def stalled_import(created_at:, pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION)
      import = import_for(account, pipeline_version: pipeline_version)
      import.update_column(:created_at, created_at)
      import
    end

    before { allow(FollowImport::ProcessImportWorker).to receive(:perform_async) }

    it 'RE-ENQUEUES the processor for a marked follow import with no batch after the grace window (never deletes it)' do
      import = stalled_import(created_at: 7.hours.ago)

      worker.perform

      # Recovery, not deletion: a queued-but-unprocessed job cannot be ruled out.
      expect(Import.exists?(import.id)).to be true
      expect(FollowImport::ProcessImportWorker).to have_received(:perform_async).with(import.id)
    end

    it 'does not enqueue an unmarked leftover follow import no matter how old it is' do
      import = stalled_import(created_at: 3.years.ago, pipeline_version: nil)

      worker.perform

      expect(Import.exists?(import.id)).to be true
      expect(FollowImport::ProcessImportWorker).not_to have_received(:perform_async)
    end

    it 'does not enqueue an unknown pipeline version even after the grace window' do
      v2 = stalled_import(created_at: 7.hours.ago, pipeline_version: 2)
      v999 = stalled_import(created_at: 3.years.ago, pipeline_version: 999)

      worker.perform

      expect(Import.exists?(v2.id)).to be true
      expect(Import.exists?(v999.id)).to be true
      expect(FollowImport::ProcessImportWorker).not_to have_received(:perform_async)
    end

    it 'leaves a recent follow import with no batch alone (its processor may still run)' do
      import = stalled_import(created_at: 10.minutes.ago)

      worker.perform

      expect(Import.exists?(import.id)).to be true
      expect(FollowImport::ProcessImportWorker).not_to have_received(:perform_async)
    end

    it 'does not touch old non-follow imports' do
      blocking = Import.create!(account: account, type: 'blocking', data: attachment_fixture('imports.txt'))
      blocking.update_column(:created_at, 7.hours.ago)

      worker.perform

      expect(Import.exists?(blocking.id)).to be true
      expect(FollowImport::ProcessImportWorker).not_to have_received(:perform_async)
    end

    it 'does not re-enqueue an old follow import that already has a batch' do
      import = stalled_import(created_at: 7.hours.ago)
      batch  = batch_with_import(import)
      add_target(batch, :pending, 0) # still dispatching -> retained by pass 1

      worker.perform

      expect(Import.exists?(import.id)).to be true
      expect(FollowImport::ProcessImportWorker).not_to have_received(:perform_async)
    end
  end

  it 'retains screening and review_required csvs even when nothing is pending' do
    screening_import = import_for(account)
    screening = batch_with_import(screening_import)
    screening.update!(preflight_state: :screening, dispatch_cohort: :operational)

    review_import = import_for(account)
    review = batch_with_import(review_import)
    review.update!(preflight_state: :review_required, dispatch_cohort: :operational)

    worker.perform

    expect(Import.exists?(screening_import.id)).to be true
    expect(Import.exists?(review_import.id)).to be true
    expect(FollowImportBatch.exists?(screening.id)).to be true
    expect(FollowImportBatch.exists?(review.id)).to be true
  end

  it 'retains a ready csv while review resume is still pending' do
    import = import_for(account)
    batch = batch_with_import(import)
    batch.mark_review_resume_required!

    worker.perform

    expect(Import.exists?(import.id)).to be true
    expect(batch.reload.review_resume_pending?).to be true
  end

  it 'drops a stopped csv even while pending target rows remain' do
    import = import_for(account)
    batch = batch_with_import(import)
    batch.update!(preflight_state: :stopped)
    target = add_target(batch, :pending, 0)

    worker.perform

    expect(Import.exists?(import.id)).to be false
    expect(FollowImportBatch.exists?(batch.id)).to be true
    expect(FollowImportTarget.exists?(target.id)).to be true
    expect(target.reload.state).to eq 'pending'
  end

  it 'drops a ready csv after resume is complete and nothing is pending' do
    import = import_for(account)
    batch = batch_with_import(import)
    batch.mark_review_resume_required!
    batch.mark_review_resume_completed!

    worker.perform

    expect(Import.exists?(import.id)).to be false
    expect(FollowImportBatch.exists?(batch.id)).to be true
  end
end
