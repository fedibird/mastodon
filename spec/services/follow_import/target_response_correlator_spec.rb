# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::TargetResponseCorrelator do
  let(:batch) do
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  def target_awaiting(uri)
    target = batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 0)
    transitions = FollowImport::TargetTransitionService.new
    transitions.mark_queued(target, follow_request_uri: uri)
    transitions.mark_awaiting_response(target, follow_request_uri: uri, response_deadline_at: 1.day.from_now)
    target
  end

  # The FollowRequest row is destroyed by authorize!/reject!, so correlation must
  # rely only on the URI. A bare double models the in-memory request.
  def request_with_uri(uri)
    instance_double('FollowRequest', uri: uri)
  end

  describe '.accepted' do
    it 'marks the correlated target accepted using follow_request_uri' do
      target = target_awaiting('https://local.test/follow-a')

      described_class.accepted(request_with_uri('https://local.test/follow-a'))

      expect(target.reload.state).to eq 'accepted'
    end
  end

  describe '.rejected' do
    it 'marks the correlated target rejected using follow_request_uri' do
      target = target_awaiting('https://local.test/follow-b')

      described_class.rejected(request_with_uri('https://local.test/follow-b'))

      expect(target.reload.state).to eq 'rejected'
    end
  end

  describe 'correlation before delivery bookkeeping (race)' do
    it 'marks a still-queued target rejected (Reject raced ahead of delivery)' do
      target = batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 0)
      FollowImport::TargetTransitionService.new.mark_queued(target, follow_request_uri: 'https://local.test/follow-race')

      described_class.rejected(request_with_uri('https://local.test/follow-race'))

      expect(target.reload.state).to eq 'rejected'
    end
  end

  describe 'safety' do
    it 'does nothing when no target matches the uri' do
      target = target_awaiting('https://local.test/follow-c')

      described_class.accepted(request_with_uri('https://local.test/unrelated'))

      expect(target.reload.state).to eq 'awaiting_response'
    end

    it 'is a no-op for a request with a blank uri' do
      expect { described_class.accepted(request_with_uri(nil)) }.not_to raise_error
      expect { described_class.rejected(nil) }.not_to raise_error
    end

    it 'never raises when the transition service fails' do
      target = target_awaiting('https://local.test/follow-d')
      allow_any_instance_of(FollowImport::TargetTransitionService).to receive(:mark_accepted).and_raise(StandardError, 'boom')

      expect { described_class.accepted(request_with_uri('https://local.test/follow-d')) }.not_to raise_error
      expect(target.reload.state).to eq 'awaiting_response'
    end
  end
end
