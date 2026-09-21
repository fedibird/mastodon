# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionReview::DecisionService do # rubocop:disable Metrics/BlockLength
  let(:reviewer) { Fabricate(:user, admin: true).account }

  def create_held_batch(preflight_state: :review_required, **attrs)
    account = Fabricate(:account)
    FollowImportBatch.create!(
      {
        subject: ModerationSubject.for_account!(account),
        imported_at: Time.now.utc,
        mode: :merge,
        dispatch_owner: :legacy,
        dispatch_cohort: :operational,
        preflight_state: preflight_state,
        target_count: 1,
        resolved_target_count: 1,
        unresolved_target_count: 0,
      }.merge(attrs)
    )
  end

  def create_request(batch, **attrs)
    ActionReviewRequest.create!(
      {
        operation_type: 'follow_import',
        state: :pending,
        actor_account: batch.for_account,
        resource: batch,
        trigger: 'policy',
        signal_level: 'none',
        policy_mode: 'always',
        policy_version: 'action-review-policy-v1',
        reason_codes: ['policy_always'],
        evidence: { 'schema_version' => 1, 'batch_id' => batch.id },
        requested_at: Time.now.utc,
      }.merge(attrs)
    )
  end

  def decide(request, verb, note: ' noted ', reviewer_account: reviewer)
    described_class.new.call(
      request: request,
      decision: verb,
      reviewer_account: reviewer_account,
      decision_note: note
    )
  end

  before do
    allow(FollowImport::ActionReviewResumeWorker).to receive(:perform_async)
  end

  it 'approves a pending follow import into ready with resume-required metadata' do
    batch = create_held_batch
    request = create_request(batch)

    expect { decide(request, 'approve', note: '  ship it  ') }.not_to change(ModerationAction, :count)

    request.reload
    batch.reload
    expect(request.approved_state?).to be true
    expect(request.reviewer_account).to eq reviewer
    expect(request.reviewed_at).to be_present
    expect(request.decision_note).to eq 'ship it'
    expect(batch.ready_preflight_state?).to be true
    expect(batch.review_resume_required?).to be true
    expect(batch.review_resume_completed?).to be false
    expect(FollowImport::ActionReviewResumeWorker).to have_received(:perform_async).with(request.id)
  end

  it 'stops a pending follow import without a moderation action' do
    batch = create_held_batch
    import = Import.create!(account: batch.for_account, type: 'following', data: attachment_fixture('new-following-imports.txt'))
    batch.update!(import_id: import.id)
    request = create_request(batch)

    expect { decide(request, 'reject', note: '') }.not_to change(ModerationAction, :count)

    expect(request.reload.rejected_state?).to be true
    expect(request.decision_note).to be_nil
    expect(request.reviewer_account).to eq reviewer
    expect(request.reviewed_at).to be_present
    expect(batch.reload.stopped_preflight_state?).to be true
    expect(Import.exists?(import.id)).to be false
    expect(FollowImportBatch.exists?(batch.id)).to be true
  end

  it 'treats a repeated approve as a no-op and still enqueues resume' do
    batch = create_held_batch
    request = create_request(batch)
    decide(request, 'approve', note: 'once')
    reviewed_at = request.reload.reviewed_at

    expect(decide(request, 'approve', note: 'twice')).to eq :already_approved

    expect(request.reload.decision_note).to eq 'once'
    expect(request.reviewed_at.to_i).to eq reviewed_at.to_i
    expect(FollowImport::ActionReviewResumeWorker).to have_received(:perform_async).with(request.id).twice
  end

  it 'refuses the opposite decision after approval' do
    batch = create_held_batch
    request = create_request(batch)
    decide(request, 'approve')

    expect { decide(request, 'reject') }.to raise_error(ActionReview::DecisionError)
    expect(request.reload.approved_state?).to be true
    expect(batch.reload.ready_preflight_state?).to be true
  end

  it 'refuses the opposite decision after rejection' do
    batch = create_held_batch
    request = create_request(batch)
    decide(request, 'reject')

    expect { decide(request, 'approve') }.to raise_error(ActionReview::DecisionError)
    expect(request.reload.rejected_state?).to be true
    expect(batch.reload.stopped_preflight_state?).to be true
  end

  it 'keeps the approval when the immediate resume enqueue is lost' do
    batch = create_held_batch
    request = create_request(batch)
    allow(FollowImport::ActionReviewResumeWorker).to receive(:perform_async).and_raise(RuntimeError, 'redis down')

    expect { decide(request, 'approve') }.not_to raise_error

    expect(request.reload.approved_state?).to be true
    expect(batch.reload.ready_preflight_state?).to be true
    expect(batch.review_resume_pending?).to be true
  end

  it 'fails closed when the batch is missing, mismatched, or not waiting' do
    missing_batch = create_held_batch
    missing = create_request(missing_batch)
    missing_batch.delete
    expect { decide(missing.reload, 'approve') }.to raise_error(ActionReview::DecisionError)

    mismatched_batch = create_held_batch
    mismatched = create_request(mismatched_batch)
    mismatched.update_column(:resource_type, 'Account')
    expect { decide(mismatched, 'approve') }.to raise_error(ActionReview::DecisionError)
    expect(mismatched.reload.pending_state?).to be true

    ready_batch = create_held_batch(preflight_state: :ready)
    waiting = create_request(ready_batch)
    expect { decide(waiting, 'approve') }.to raise_error(ActionReview::DecisionError)
    expect(waiting.reload.pending_state?).to be true
    expect(ready_batch.reload.ready_preflight_state?).to be true
  end

  it 'has no decision adapter for an unintegrated operation' do
    resource = Fabricate(:account)
    request = ActionReviewRequest.create!(
      operation_type: 'invite_creation',
      state: :pending,
      actor_account: resource,
      resource: resource,
      trigger: 'policy',
      signal_level: 'none',
      policy_mode: 'always',
      policy_version: 'action-review-policy-v1',
      reason_codes: ['policy_always'],
      evidence: {},
      requested_at: Time.now.utc
    )

    expect { decide(request, 'approve') }.to raise_error(ActionReview::AdapterRegistry::UnknownAdapter)
    expect(request.reload.pending_state?).to be true
    expect(ActionReview::AdapterRegistry.registered?('invite_creation')).to be false
    expect(ActionReview::AdapterRegistry.registered?('account_migration')).to be false
    expect(ActionReview::AdapterRegistry.registered?('status_import')).to be false
  end

  describe 'concurrent moderators' do
    self.use_transactional_tests = false

    after do
      ActionReviewRequest.delete_all
      FollowImportTarget.delete_all
      FollowImportBatch.delete_all
      Import.delete_all
    end

    it 'lets exactly one terminal decision win' do
      batch = create_held_batch
      request = create_request(batch)
      other = Fabricate(:user, moderator: true).account
      start = Queue.new
      winners = Queue.new
      errors = Queue.new

      threads = [
        [reviewer.id, 'approve'],
        [other.id, 'reject'],
      ].map do |actor_id, verb|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            start.pop
            fresh = ActionReviewRequest.find(request.id)
            actor = Account.find(actor_id)
            decide(fresh, verb, note: verb, reviewer_account: actor)
            winners << verb
          rescue ActionReview::DecisionError
            errors << verb
          rescue StandardError => e
            errors << "#{verb}:#{e.class}:#{e.message}"
          end
        end
      end

      2.times { start << true }
      threads.each { |thread| thread.join(10) }

      expect(threads.all?(&:stop?)).to be true
      expect(winners.size).to eq 1
      expect(errors.size).to eq 1
      request.reload
      batch.reload
      expect(request.pending_state?).to be false
      if request.approved_state?
        expect(batch.ready_preflight_state?).to be true
      else
        expect(request.rejected_state?).to be true
        expect(batch.stopped_preflight_state?).to be true
      end
    end
  end
end
