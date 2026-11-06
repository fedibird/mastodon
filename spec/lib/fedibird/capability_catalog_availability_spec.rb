# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Fedibird::CapabilityCatalog do
  describe '.availability' do
    it 'reflects instance search and poll-image switches' do
      allow(Chewy).to receive(:enabled?).and_return(false)
      allow(Setting).to receive(:allow_poll_image).and_return(false)
      expect(described_class.availability.dig(:search, :enabled)).to be(false)
      expect(described_class.availability.dig(:poll_images, :enabled)).to be(false)

      allow(Chewy).to receive(:enabled?).and_return(true)
      allow(Setting).to receive(:allow_poll_image).and_return(true)
      expect(described_class.availability.dig(:search, :enabled)).to be(true)
      expect(described_class.availability.dig(:poll_images, :enabled)).to be(true)
    end

    it 'only reports the server switch for allowlisted external bridges' do
      allow(ExternalBridge::Feature).to receive(:enabled?).and_return(true)
      allow(ExternalBridge::Feeds::Feature).to receive(:enabled?).and_return(true)
      expect(ExternalBridge::Feature).not_to receive(:permitted?)
      expect(ExternalBridge::Feeds::Feature).not_to receive(:permitted?)

      result = described_class.availability
      expect(result[:rss_subscriptions]).to eq(scope: 'allowlisted_user', server_enabled: true)
      expect(result.dig(:external_feed_delivery, :server_enabled)).to be(true)
      expect(result.dig(:external_feed_delivery, :viewer_check_path)).to eq('/api/v1/timelines/external_feed_capability')
    end

    it 'reports only effective emoji fallback enforcement, without warnings' do
      allow(EmojiReactionCapability::FallbackPolicyConfig).to receive(:requested?).and_return(true)
      allow(EmojiReactionCapability::FallbackPolicyConfig).to receive(:prerequisites_met?).and_return(false)
      expect(EmojiReactionCapability::FallbackPolicyConfig).not_to receive(:effective?)
      expect(described_class.availability.dig(:emoji_reaction_fallback_policy, :enforcement_enabled)).to be(false)

      allow(EmojiReactionCapability::FallbackPolicyConfig).to receive(:prerequisites_met?).and_return(true)
      expect(described_class.availability.dig(:emoji_reaction_fallback_policy, :enforcement_enabled)).to be(true)
    end
  end
end
