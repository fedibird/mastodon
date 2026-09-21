# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::CsvRetention do
  let(:account) { Fabricate(:account) }

  def create_batch(preflight_state:)
    import = Import.create!(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt'))
    FollowImportBatch.create!(
      subject: ModerationSubject.for_account!(account),
      import_id: import.id,
      imported_at: Time.now.utc,
      mode: :merge,
      dispatch_owner: :legacy,
      dispatch_cohort: :operational,
      preflight_state: preflight_state,
      target_count: 0,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
  end

  it 'retains the csv from the legacy finalizer while an approved resume is pending' do
    batch = create_batch(preflight_state: :ready)
    batch.mark_review_resume_required!

    FollowImport::BatchExecutionWorker.new.send(:finalize_import!, batch)

    expect(Import.exists?(batch.import_id)).to be true
  end

  it 'retains the csv from the global finalizer while an approved resume is pending' do
    batch = create_batch(preflight_state: :ready)
    batch.mark_review_resume_required!
    executor = FollowImport::DispatchExecutor.new(lease: nil)

    executor.send(:release_csv_if_dispatched, batch)

    expect(Import.exists?(batch.import_id)).to be true
  end

  it 'allows cleanup once resume is complete and nothing is pending' do
    batch = create_batch(preflight_state: :ready)
    batch.mark_review_resume_required!
    batch.mark_review_resume_completed!

    expect(described_class.retain?(batch)).to be false
  end
end
