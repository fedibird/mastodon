# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Fedibird::CapabilityCatalog do
  describe '.instance integrations' do
    it 'keeps Bluesky OAuth outside REST and ActivityPub and never checks a user' do
      allow(ExternalBridge::Atproto::Feature).to receive(:enabled?).and_return(true)
      allow(ExternalBridge::Atproto::ClientDocument).to receive(:configured?).and_return(true)
      expect(ExternalBridge::Atproto::Feature).not_to receive(:permitted?)
      expect(ExternalBridge::Atproto::Feature).not_to receive(:tester_ids)

      info = described_class.instance
      bluesky = info.dig(:integrations, :bluesky_oauth)

      expect(bluesky).to eq(
        scope: 'allowlisted_user',
        interface: 'browser_oauth',
        server_enabled: true,
        oauth_client_configured: true,
        settings_path: '/settings/external_services/bluesky',
      )
      expect(info.dig(:rest, :supported)).not_to include('bluesky_oauth')
      expect(info[:activitypub]).not_to have_key(:bluesky_oauth)
    end

    it 'distinguishes a disabled server from missing OAuth configuration' do
      allow(ExternalBridge::Atproto::Feature).to receive(:enabled?).and_return(false)
      allow(ExternalBridge::Atproto::ClientDocument).to receive(:configured?).and_return(true)

      info = described_class.instance.dig(:integrations, :bluesky_oauth)
      expect(info[:server_enabled]).to be(false)
      expect(info[:oauth_client_configured]).to be(true)

      allow(ExternalBridge::Atproto::Feature).to receive(:enabled?).and_return(true)
      allow(ExternalBridge::Atproto::ClientDocument).to receive(:configured?).and_return(false)

      info = described_class.instance.dig(:integrations, :bluesky_oauth)
      expect(info[:server_enabled]).to be(true)
      expect(info[:oauth_client_configured]).to be(false)
    end

    it 'does not add web OAuth metadata to NodeInfo' do
      expect(described_class.nodeinfo).not_to have_key(:integrations)
    end
  end
end
