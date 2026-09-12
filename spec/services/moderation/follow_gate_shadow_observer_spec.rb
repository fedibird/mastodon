# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::FollowGateShadowObserver do
  let(:source) { Fabricate(:account, username: 'shadow_source') }
  let(:target) { Fabricate(:account, username: 'shadow_target', locked: true) }

  describe '.observe' do
    context 'when the shadow flag is off (default)' do
      it 'does not enqueue anything' do
        allow(described_class).to receive(:enabled?).and_return(false)
        expect(Moderation::FollowGateShadowWorker).to_not receive(:perform_async)

        described_class.observe(source_account: source, target_account: target)
      end
    end

    context 'when the shadow flag is on' do
      before { allow(described_class).to receive(:enabled?).and_return(true) }

      it 'enqueues the shadow worker with a behaviour-neutral context' do
        expect(Moderation::FollowGateShadowWorker).to receive(:perform_async).with(
          source.id,
          { 'mechanism' => 'follow_import', 'target_locality' => 'local', 'target_locked' => true }
        )

        described_class.observe(source_account: source, target_account: target, mechanism: 'follow_import')
      end

      it 'marks a remote unlocked target correctly' do
        remote = Fabricate(:account, username: 'shadow_remote', domain: 'remote.example', locked: false, protocol: :activitypub)
        expect(Moderation::FollowGateShadowWorker).to receive(:perform_async).with(
          source.id, a_hash_including('target_locality' => 'remote', 'target_locked' => false)
        )

        described_class.observe(source_account: source, target_account: remote)
      end

      it 'is failure-tolerant: a raising enqueue never propagates' do
        allow(Moderation::FollowGateShadowWorker).to receive(:perform_async).and_raise(StandardError, 'boom')

        expect { described_class.observe(source_account: source, target_account: target) }.to_not raise_error
      end
    end
  end
end
