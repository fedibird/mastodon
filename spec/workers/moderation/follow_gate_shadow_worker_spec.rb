# frozen_string_literal: true

require 'rails_helper'

describe Moderation::FollowGateShadowWorker do
  let(:account) { Fabricate(:account, username: 'shadow_worker_actor') }

  describe '#perform' do
    it 'logs the would-be friction from the shadow decision without applying anything' do
      logged = nil
      allow(Rails.logger).to receive(:info) { |msg| logged = msg }

      described_class.new.perform(account.id, { 'mechanism' => 'api', 'target_locality' => 'remote' })

      expect(logged).to include('[Moderation::FollowGateShadow]')
      payload = JSON.parse(logged.sub('[Moderation::FollowGateShadow] ', ''))
      expect(payload['shadow']).to be true
      # No ledger history -> the gate would propose allow.
      expect(payload['would_friction']).to eq 'allow'
      expect(payload['policy_version']).to eq Moderation::AdaptiveFollowGateDecisionService::POLICY_VERSION
      expect(payload['context']).to include('mechanism' => 'api', 'target_locality' => 'remote')
    end

    it 'returns quietly for a missing account' do
      expect { described_class.new.perform(0, {}) }.to_not raise_error
    end

    it 'is failure-tolerant if the decision service raises' do
      allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call).and_raise(StandardError, 'boom')

      expect { described_class.new.perform(account.id, {}) }.to_not raise_error
    end

    it 'evaluates as of the attempt time, excluding events that happened after it' do
      t0     = 90.minutes.ago.change(usec: 0)
      before = Fabricate(:account, username: 'shadow_before')
      after  = Fabricate(:account, username: 'shadow_after')

      # One contact before the attempt, one after it.
      Moderation::EventRecorder.record_interaction(actor: account, target: before, event_type: :follow, occurred_at: t0 - 10.minutes, source_event_key: 's-before')
      Moderation::EventRecorder.record_interaction(actor: account, target: after, event_type: :follow, occurred_at: t0 + 30.minutes, source_event_key: 's-after')

      # The worker threads the attempt time through to the gate decision as `now`.
      captured_now = nil
      allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call).and_wrap_original do |method, *args, **kwargs|
        captured_now = kwargs[:now]
        method.call(*args, **kwargs)
      end

      described_class.new.perform(account.id, {}, t0.utc.iso8601)
      expect(captured_now.to_i).to eq t0.to_i

      # And at that `now`, the underlying metrics exclude the post-attempt contact
      # (1), while evaluating now would include both (2) — i.e. no future leakage.
      expect(Moderation::BehavioralMetricsService.new.call(account, now: t0).dig('windows', '24h', 'contacts_total')).to eq 1
      expect(Moderation::BehavioralMetricsService.new.call(account, now: Time.now.utc).dig('windows', '24h', 'contacts_total')).to eq 2
    end
  end
end
