# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::TargetTransitionService do
  subject(:service) { described_class.new }

  let(:batch) do
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  def new_target
    batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 0)
  end

  describe 'legacy defaults' do
    it 'defaults a freshly created target to pending and non-terminal' do
      target = new_target
      expect(target.state).to eq 'pending'
      expect(target.terminal?).to be false
    end
  end

  describe 'the happy-path lifecycle' do
    it 'walks pending -> queued -> awaiting_delivery -> awaiting_response -> accepted, setting timestamps' do
      target   = new_target
      deadline = FollowImport::ExecutionPolicy.response_deadline_at

      service.mark_queued(target)
      expect(target.reload.state).to eq 'queued'
      expect(target.queued_at).to be_present

      service.mark_awaiting_delivery(target)
      expect(target.reload.state).to eq 'awaiting_delivery'

      service.mark_awaiting_response(target, follow_request_uri: 'https://local.test/abc', response_deadline_at: deadline)
      target.reload
      expect(target.state).to eq 'awaiting_response'
      expect(target.follow_request_uri).to eq 'https://local.test/abc'
      expect(target.delivered_at).to be_present
      expect(target.response_deadline_at).to be_within(1).of(deadline)

      service.mark_accepted(target)
      target.reload
      expect(target.state).to eq 'accepted'
      expect(target.completed_at).to be_present
      expect(target.terminal?).to be true
    end
  end

  describe 'idempotency' do
    it 'treats a repeated transition as a no-op and does not rewrite its timestamp' do
      target = new_target
      service.mark_queued(target)
      first_queued_at = target.reload.queued_at

      service.mark_queued(target)
      expect(target.reload.state).to eq 'queued'
      expect(target.queued_at).to eq first_queued_at
    end

    it 'ignores a duplicate accept' do
      target = new_target
      service.transition(target, 'awaiting_response')
      service.mark_accepted(target)
      first_completed = target.reload.completed_at

      service.mark_accepted(target)
      expect(target.reload.completed_at).to eq first_completed
    end
  end

  describe 'terminal states are final' do
    it 'does not let a late delivery callback roll an accepted target back to awaiting_response' do
      target = new_target
      service.transition(target, 'awaiting_response')
      service.mark_accepted(target)

      service.mark_awaiting_response(target, follow_request_uri: 'https://local.test/late', response_deadline_at: 1.day.from_now)

      target.reload
      expect(target.state).to eq 'accepted'
      expect(target.follow_request_uri).to be_nil # not overwritten by the late callback
    end

    it 'ignores a reject that arrives after an accept (terminal not overwritten)' do
      target = new_target
      service.transition(target, 'awaiting_response')
      service.mark_accepted(target)

      service.mark_rejected(target)
      expect(target.reload.state).to eq 'accepted'
    end

    context 'when an Accept/Reject races ahead of delivery bookkeeping' do
      it 'accepts from awaiting_delivery and stays accepted after a late delivery callback' do
        target = new_target
        service.mark_queued(target)
        service.mark_awaiting_delivery(target)

        # Accept observed before the delivery-success callback runs.
        service.mark_accepted(target)
        expect(target.reload.state).to eq 'accepted'

        # Late delivery bookkeeping must not roll it back, nor a later sweep.
        service.mark_awaiting_response(target, follow_request_uri: 'https://local.test/late', response_deadline_at: 1.day.from_now)
        service.mark_completed_no_response(target)

        target.reload
        expect(target.state).to eq 'accepted'
        expect(target.follow_request_uri).to be_nil
      end

      it 'rejects from awaiting_delivery and stays rejected after a late delivery callback' do
        target = new_target
        service.mark_queued(target)
        service.mark_awaiting_delivery(target)

        service.mark_rejected(target)
        expect(target.reload.state).to eq 'rejected'

        service.mark_awaiting_response(target, follow_request_uri: 'https://local.test/late', response_deadline_at: 1.day.from_now)
        service.mark_completed_no_response(target)

        expect(target.reload.state).to eq 'rejected'
      end

      it 'accepts even directly from queued (earliest correlatable state)' do
        target = new_target
        service.mark_queued(target)

        service.mark_accepted(target)
        expect(target.reload.state).to eq 'accepted'

        service.mark_awaiting_response(target, follow_request_uri: 'https://local.test/late', response_deadline_at: 1.day.from_now)
        expect(target.reload.state).to eq 'accepted'
      end
    end

    %i[accepted rejected completed_no_response delivery_failed].each do |terminal|
      it "reaches the terminal state #{terminal}" do
        target = new_target
        service.transition(target, 'awaiting_response')
        service.public_send("mark_#{terminal}", target)

        target.reload
        expect(target.state).to eq terminal.to_s
        expect(target.terminal?).to be true
        expect(target.completed_at).to be_present
      end
    end
  end

  describe 'delivery bookkeeping' do
    it 'records delivery attempts without changing state' do
      target = new_target
      service.record_delivery_attempt(target)
      service.record_delivery_attempt(target)

      target.reload
      expect(target.delivery_attempts).to eq 2
      expect(target.state).to eq 'pending'
    end

    it 'captures a failure_code on delivery_failed' do
      target = new_target
      service.mark_delivery_failed(target, failure_code: 'retries_exhausted')
      expect(target.reload.failure_code).to eq 'retries_exhausted'
      expect(target.state).to eq 'delivery_failed'
    end
  end
end
