# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduler::FollowImportCsvCleanupScheduler do
  subject(:worker) { described_class.new }

  let(:account) { Fabricate(:account) }

  def import_for(account)
    Import.create!(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt'))
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

  it 'is a no-op for a batch whose import is already gone' do
    batch = FollowImportBatch.create!(subject: ModerationSubject.for_account!(account), import_id: 999_999,
                                      imported_at: Time.now.utc, mode: :merge, target_count: 0,
                                      resolved_target_count: 0, unresolved_target_count: 0)
    add_target(batch, :accepted, 0)

    expect { worker.perform }.not_to raise_error
  end

  describe 'orphaned follow imports (handoff enqueue lost)' do
    def orphan_import(created_at:)
      import = import_for(account)
      import.update_column(:created_at, created_at)
      import
    end

    it 'drops a follow import that still has no batch after the grace window' do
      import = orphan_import(created_at: 7.hours.ago)

      worker.perform

      expect(Import.exists?(import.id)).to be false
    end

    it 'leaves a recent follow import with no batch alone (its processor may still run)' do
      import = orphan_import(created_at: 10.minutes.ago)

      worker.perform

      expect(Import.exists?(import.id)).to be true
    end

    it 'does not touch old non-follow imports (only follow imports are reclaimed here)' do
      blocking = Import.create!(account: account, type: 'blocking', data: attachment_fixture('imports.txt'))
      blocking.update_column(:created_at, 7.hours.ago)

      worker.perform

      expect(Import.exists?(blocking.id)).to be true
    end

    it 'leaves an old follow import that DID get a batch to the dispatch-completion rule' do
      import = orphan_import(created_at: 7.hours.ago)
      batch  = batch_with_import(import)
      add_target(batch, :pending, 0) # still dispatching -> retained

      worker.perform

      expect(Import.exists?(import.id)).to be true
    end
  end
end
