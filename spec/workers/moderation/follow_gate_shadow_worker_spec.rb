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
  end
end
