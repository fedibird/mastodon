# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::ActionReviewResumeWorker do # rubocop:disable Metrics/BlockLength
  subject(:worker) { described_class.new }

  let(:account) { Fabricate(:account) }

  def create_batch(owner: :legacy, mode: :merge, preflight_state: :ready)
    import = Import.create!(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt'))
    batch = FollowImportBatch.create!(
      subject: ModerationSubject.for_account!(account),
      import_id: import.id,
      imported_at: Time.now.utc,
      mode: mode,
      dispatch_owner: owner,
      dispatch_cohort: :operational,
      preflight_state: preflight_state,
      target_count: 1,
      resolved_target_count: 1,
      unresolved_target_count: 0
    )
    batch.mark_review_resume_required! if batch.ready_preflight_state?
    batch
  end

  def create_request(batch, state: :approved)
    ActionReviewRequest.create!(
      operation_type: 'follow_import',
      state: state,
      actor_account: account,
      resource: batch,
      trigger: 'policy',
      signal_level: 'none',
      policy_mode: 'always',
      policy_version: 'action-review-policy-v1',
      reason_codes: ['policy_always'],
      evidence: { 'schema_version' => 1 },
      requested_at: Time.now.utc,
      reviewer_account: Fabricate(:account),
      reviewed_at: Time.now.utc
    )
  end

  before do
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
    allow(Import::RelationshipWorker).to receive(:perform_async)
  end

  it 're-hands a legacy batch to BatchExecutionWorker and marks resume complete' do
    batch = create_batch
    request = create_request(batch)

    worker.perform(request.id)

    expect(FollowImport::BatchExecutionWorker).to have_received(:perform_async).with(batch.id)
    expect(batch.reload.review_resume_completed?).to be true
    expect(batch.legacy_dispatch_owner?).to be true
  end

  it 'does not convert a scheduler-owned batch to the legacy worker' do
    batch = create_batch(owner: :scheduler)
    request = create_request(batch)

    worker.perform(request.id)

    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    expect(batch.reload.scheduler_dispatch_owner?).to be true
    expect(batch.review_resume_completed?).to be true
  end

  it 'enqueues overwrite removals only while resuming an approved overwrite import' do
    other = Fabricate(:account, username: 'carol')
    account.follow!(other)
    batch = create_batch(mode: :overwrite)
    request = create_request(batch)

    worker.perform(request.id)

    expect(Import::RelationshipWorker).to have_received(:perform_async).with(account.id, 'carol', 'unfollow', {})
    expect(batch.reload.review_resume_completed?).to be true
  end

  it 'is a no-op once resume is already completed' do
    batch = create_batch
    batch.mark_review_resume_completed!
    request = create_request(batch)

    worker.perform(request.id)

    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
  end

  it 'ignores a request that is not an approved follow import' do
    batch = create_batch
    pending = create_request(batch, state: :pending)

    worker.perform(pending.id)
    worker.perform(-1)

    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    expect(batch.reload.review_resume_completed?).to be false
  end

  it 'leaves the resume marker pending when the batch is not ready' do
    batch = create_batch(preflight_state: :review_required)
    request = create_request(batch)

    expect { worker.perform(request.id) }.to raise_error(RuntimeError, 'batch is not ready')
    expect(batch.reload.review_resume_completed?).to be false
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
  end

  it 'leaves the resume marker pending when completion cannot be recorded' do
    batch = create_batch
    request = create_request(batch)
    allow_any_instance_of(FollowImportBatch).to receive(:mark_review_resume_completed!).and_raise(RuntimeError, 'marker')

    expect { worker.perform(request.id) }.to raise_error(RuntimeError, 'marker')
    expect(batch.reload.review_resume_completed?).to be false
    expect(FollowImport::BatchExecutionWorker).to have_received(:perform_async).with(batch.id)
  end

  it 'leaves the resume marker pending when the csv is already gone' do
    batch = create_batch
    Import.find(batch.import_id).destroy
    request = create_request(batch)

    expect { worker.perform(request.id) }.to raise_error(RuntimeError, 'follow import csv is missing')
    expect(batch.reload.review_resume_completed?).to be false
  end
end
