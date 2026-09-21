# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduler::FollowImportActionReviewResumeScheduler do # rubocop:disable Metrics/BlockLength
  subject(:worker) { described_class.new }

  let(:account) { Fabricate(:account) }

  def create_case(completed: false, preflight_state: :ready, with_import: true, state: :approved)
    import = Import.create!(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt'))
    batch = FollowImportBatch.create!(
      subject: ModerationSubject.for_account!(account),
      import_id: with_import ? import.id : nil,
      imported_at: Time.now.utc,
      mode: :merge,
      dispatch_owner: :legacy,
      dispatch_cohort: :operational,
      preflight_state: preflight_state,
      target_count: 0,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
    batch.mark_review_resume_required! if preflight_state.to_s == 'ready' || preflight_state == :ready
    batch.update!(preflight_state: preflight_state) unless batch.preflight_state == preflight_state.to_s
    batch.mark_review_resume_completed! if completed
    import.destroy unless with_import
    request = ActionReviewRequest.create!(
      operation_type: 'follow_import',
      state: state,
      actor_account: account,
      resource: batch,
      trigger: 'policy',
      signal_level: 'none',
      policy_mode: 'always',
      policy_version: 'action-review-policy-v1',
      reason_codes: ['policy_always'],
      evidence: {},
      requested_at: Time.now.utc
    )
    [request, batch]
  end

  before do
    allow(FollowImport::ActionReviewResumeWorker).to receive(:perform_async)
  end

  it 'enqueues resume for an approved ready batch that still has its import' do
    request, = create_case

    worker.perform

    expect(FollowImport::ActionReviewResumeWorker).to have_received(:perform_async).with(request.id)
  end

  it 'ignores a resume that is already completed' do
    create_case(completed: true)

    worker.perform

    expect(FollowImport::ActionReviewResumeWorker).not_to have_received(:perform_async)
  end

  it 'ignores a batch that is not ready or has lost its import' do
    create_case(preflight_state: :review_required)
    create_case(with_import: false)
    create_case(state: :pending)

    worker.perform

    expect(FollowImport::ActionReviewResumeWorker).not_to have_received(:perform_async)
  end

  it 'bounds each pass' do
    relation = ActionReviewRequest.none
    allow(worker).to receive(:unfinished_requests).and_return(relation)
    expect(relation).to receive(:limit).with(described_class::BATCH_LIMIT).and_return(relation)

    worker.perform
  end
end
