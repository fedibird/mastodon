# frozen_string_literal: true

require 'rails_helper'

describe ExternalServices::Registry do
  let(:user) { Fabricate(:user) }

  it 'lists DeepL only and does not decrypt while building cards' do
    with_vault_keyring do
      store_vault_credential(owner: user, secret: 'registry-safe-deepl-key')
      expect(UserCredentialVault::Cipher).not_to receive(:decrypt)
      expect(UserCredentialVault).not_to receive(:with_credential)

      cards = described_class.connections_for(user)

      expect(described_class.providers).to eq([ExternalServices::DeepL])
      expect(cards.size).to eq(1)
      expect(cards.first.provider_key).to eq('deepl')
      expect(cards.first.status).to eq(:connected)
      expect(cards.first.icon).to eq(ExternalServices::DeepL.icon)
      expect(cards.first.manage_path).to eq('/settings/external_services/deepl')
      expect(cards.first.instance_variables).not_to include(:@encrypted_payload)
    end
  end

  it 'flattens zero or more connections from each provider' do
    provider = Class.new do
      def self.connections_for(_user)
        [
          ExternalServices::Connection.new(provider_key: 'example', title: 'One', subtitle: 'a', status: :connected, status_label: 'Configured', manage_path: '/one', icon: 'external_services/deepl.svg'),
          ExternalServices::Connection.new(provider_key: 'example', title: 'Two', subtitle: 'b', status: :warning, status_label: 'Needs attention', manage_path: '/two', icon: 'external_services/deepl.svg'),
        ]
      end

      def self.available?
        true
      end

      def self.catalog_entry_for(_user)
        ExternalServices::CatalogEntry.new(provider_key: 'example', title: 'Example', description: 'Example service', icon: 'external_services/deepl.svg', configured: false, action: :add, path: '/example')
      end
    end
    hidden = Class.new do
      def self.connections_for(_user)
        []
      end

      def self.available?
        false
      end

      def self.catalog_entry_for(_user)
        raise 'hidden providers are not listed'
      end
    end

    allow(described_class).to receive(:providers).and_return([provider, hidden, ExternalServices::DeepL])
    expect(UserCredentialVault::Cipher).not_to receive(:decrypt)

    cards = described_class.connections_for(user)
    catalog = described_class.catalog_for(user)

    expect(cards.map(&:title)).to eq(['One', 'Two'])
    expect(catalog.map(&:provider_key)).to eq(%w(example deepl))
  end

  it 'returns one DeepL card for duplicate rows and no card when nothing is configured' do
    with_vault_keyring do
      expect(ExternalServices::DeepL.connections_for(user)).to eq([])

      Array.new(2) { store_vault_credential(owner: user, secret: "dup-#{SecureRandom.hex(8)}") }
      cards = ExternalServices::DeepL.connections_for(user)

      expect(cards.size).to eq(1)
      expect(cards.first.status).to eq(:warning)
    end
  end

  it 'treats a revoked or expired DeepL row as a warning, not a remote connection' do
    with_vault_keyring do
      revoked = store_vault_credential(owner: user, secret: 'revoked-deepl-key')
      revoked.update!(revoked_at: 1.hour.ago)
      expect(ExternalServices::DeepL.connections_for(user).first.status).to eq(:warning)

      revoked.update!(revoked_at: nil, expires_at: 1.hour.ago)
      card = ExternalServices::DeepL.connections_for(user).first
      expect(card.status).to eq(:warning)
      expect(card.status_label).not_to match(/verified/i)
    end
  end

  it 'does not treat a missing DeepL row as configured when the vault is unavailable' do
    with_vault_keyring(primary: '', keys: '') do
      entry = ExternalServices::DeepL.catalog_entry_for(user)

      expect(entry.configured?).to be false
      expect(entry.status).to eq(:unavailable)
      expect(entry.action).to eq(:add)
    end
  end

  it 'keeps an existing DeepL row configured when its status is warning or unavailable' do
    with_vault_keyring do
      Array.new(2) { store_vault_credential(owner: user, secret: "dup-#{SecureRandom.hex(8)}") }
      warning = ExternalServices::DeepL.catalog_entry_for(user)

      expect(warning.configured?).to be true
      expect(warning.status).to eq(:warning)
      expect(warning.action).to eq(:manage)
    end

    with_vault_keyring(primary: '', keys: '') do
      unavailable = ExternalServices::DeepL.catalog_entry_for(user)

      expect(unavailable.configured?).to be true
      expect(unavailable.status).to eq(:unavailable)
      expect(unavailable.action).to eq(:manage)
    end
  end

  it 'rejects a catalog action outside add and manage' do
    expect do
      ExternalServices::CatalogEntry.new(provider_key: 'example', title: 'Example', description: 'Example service', icon: 'external_services/deepl.svg', configured: false, action: :create, path: '/example')
    end.to raise_error(ArgumentError, 'unknown catalog action')
  end

  it 'marks an existing DeepL connection unavailable without the vault keyring' do
    with_vault_keyring { store_vault_credential(owner: user, secret: 'stored-before-keyring-loss') }

    with_vault_keyring(primary: '', keys: '') do
      card = ExternalServices::DeepL.connections_for(user).first

      expect(card.status).to eq(:unavailable)
      expect(card.status_label).to eq(I18n.t('external_services.status.unavailable'))
    end
  end
end
