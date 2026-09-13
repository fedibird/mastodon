# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::TargetDeliveryTracker do
  let(:batch) do
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  def new_target
    batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 0)
  end

  describe '.delivered' do
    it 'advances a queued target to awaiting_response with a deadline' do
      target = new_target
      FollowImport::TargetTransitionService.new.mark_queued(target, follow_request_uri: 'https://local.test/req-1')

      described_class.delivered(target.id)

      target.reload
      expect(target.state).to eq 'awaiting_response'
      expect(target.delivered_at).to be_present
      expect(target.response_deadline_at).to be_present
      expect(target.follow_request_uri).to eq 'https://local.test/req-1'
    end

    it 'does not overwrite a target that was already accepted (Accept won the race)' do
      target = new_target
      transitions = FollowImport::TargetTransitionService.new
      transitions.mark_queued(target, follow_request_uri: 'https://local.test/req-2')
      transitions.mark_accepted(target)

      described_class.delivered(target.id)

      expect(target.reload.state).to eq 'accepted'
    end

    it 'is a no-op for an unknown target id' do
      expect { described_class.delivered(-1) }.not_to raise_error
    end
  end

  describe '.failed' do
    it 'marks a queued target delivery_failed with a failure code' do
      target = new_target
      FollowImport::TargetTransitionService.new.mark_queued(target, follow_request_uri: 'https://local.test/req-3')

      described_class.failed(target.id)

      target.reload
      expect(target.state).to eq 'delivery_failed'
      expect(target.failure_code).to eq 'delivery_retries_exhausted'
    end

    it 'is a no-op for an unknown target id' do
      expect { described_class.failed(-1) }.not_to raise_error
    end
  end
end
