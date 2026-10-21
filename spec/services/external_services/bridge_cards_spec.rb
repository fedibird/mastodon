# frozen_string_literal: true

require 'rails_helper'

describe 'External service bridge cards' do
  let(:user) { Fabricate(:user) }

  def feed_for(owner, state: 'active', failed_item_count: 0, last_error_code: nil, title: 'Public feed')
    source = ExternalSource.create!(
      protocol: 'rss',
      canonical_key: "https://feeds.example/#{SecureRandom.hex(4)}.xml",
      title: title
    )
    ExternalSubscription.create!(
      user: owner,
      external_source: source,
      state: state,
      failed_item_count: failed_item_count,
      last_error_code: last_error_code,
      checked_at: Time.zone.parse('2026-10-20 12:00:00 UTC')
    )
  end

  def identity_for(owner, status: 'connected', handle: 'alice.example')
    ExternalIdentity.create!(
      user: owner,
      provider: 'bluesky',
      subject: "did:plc:#{SecureRandom.hex(8)}",
      issuer: 'https://entry.example',
      resource_origin: 'https://pds.example',
      token_endpoint: 'https://entry.example/oauth/token',
      handle: handle,
      status: status,
      terms_state: 'unreviewed',
      granted_scopes: ['atproto'],
      disconnected_at: (status == 'disconnected' ? Time.zone.parse('2026-10-20 12:00:00 UTC') : nil)
    )
  end

  it 'keeps both bridge flags off with an empty tester list' do
    text = File.read(Rails.root.join('config/settings.yml'))

    expect(text).to include('external_bridge_rss: false')
    expect(text).to include("external_bridge_rss_testers: ''")
    expect(text).to include('external_bridge_atproto: false')
    expect(text).to include("external_bridge_atproto_testers: ''")
  end

  it 'summarizes RSS feeds in one query and hides them from another user' do
    other = share_account_user(user.account)
    feed_for(user, state: 'active')
    feed_for(user, state: 'paused')
    feed_for(user, state: 'error', last_error_code: 'fetch_failed')
    enable_external_bridge_rss!(user)

    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      queries << payload[:sql] unless payload[:name] == 'SCHEMA'
    end
    cards = nil
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      cards = ExternalServices::RSS.connections_for(user)
    end

    expect(queries.size).to eq(1)
    expect(cards.size).to eq(1)
    expect(cards.first.title).to eq(I18n.t('external_services.providers.rss.name'))
    expect(cards.first.subtitle).to include('3')
    expect(cards.first.status).to eq(:warning)
    expect(cards.first.manage_label).to eq(I18n.t('external_services.actions.rss.manage'))
    expect(ExternalServices::RSS.connections_for(other)).to eq([])
    expect(ExternalServices::Registry.catalog_for(other).map(&:provider_key)).not_to include('rss')
  end

  it 'labels an all-paused RSS summary as paused and keeps the catalog specific' do
    feed_for(user, state: 'paused')
    enable_external_bridge_rss!(user)

    card = ExternalServices::RSS.connections_for(user).first
    entry = ExternalServices::Registry.catalog_for(user).find { |row| row.provider_key == 'rss' }

    expect(card.status).to eq(:warning)
    expect(card.status_label).to eq(I18n.t('external_bridge.state.paused'))
    expect(entry.action_label).to eq(I18n.t('external_services.actions.rss.manage'))
    expect(entry.configured?).to be(true)
  end

  it 'keeps an existing RSS card manageable when the flag is off and out of the catalog' do
    feed_for(user)
    Setting.external_bridge_rss = false

    card = ExternalServices::RSS.connections_for(user).first

    expect(card.status).to eq(:unavailable)
    expect(ExternalServices::Registry.catalog_for(user).map(&:provider_key)).not_to include('rss')
    expect(ExternalServices::RSS.page_for(user).show_form?).to be(false)
  end

  it 'summarizes Bluesky identities without mixing owners or advertising the feature' do
    other = share_account_user(user.account)
    identity_for(user, status: 'connected', handle: 'alice.example')
    identity_for(user, status: 'reauthentication_required', handle: 'bob.example')
    identity_for(user, status: 'disconnected', handle: 'cara.example')

    cards = ExternalServices::Bluesky.connections_for(user)

    expect(cards.size).to eq(1)
    expect(cards.first.status).to eq(:reauthentication_required)
    expect(cards.first.subtitle).to include('3')
    expect(cards.first.manage_label).to eq(I18n.t('external_services.actions.bluesky.manage'))
    expect(ExternalServices::Bluesky.connections_for(other)).to eq([])
    expect(ExternalServices::Registry.catalog_for(user).map(&:provider_key)).not_to include('bluesky')
  end

  it 'offers Bluesky status to a tester when the signing key is missing' do
    enable_atproto!(user)

    entry = ExternalServices::Registry.catalog_for(user).find { |row| row.provider_key == 'bluesky' }

    expect(entry.action_label).to eq(I18n.t('external_services.actions.bluesky.unavailable'))
    expect(entry.configured?).to be(false)
    expect(entry.status).to eq(:unavailable)
    expect(ExternalServices::Bluesky.available?).to be(false)
  end

  it 'uses the connect verb only when a tester can start OAuth' do
    with_atproto_client do
      enable_atproto!(user)
      entry = ExternalServices::Registry.catalog_for(user).find { |row| row.provider_key == 'bluesky' }

      expect(entry.action_label).to eq(I18n.t('external_services.actions.bluesky.add'))
      expect(ExternalServices::Bluesky.available?).to be(true)
    end
  end

  it 'distinguishes a disconnected Bluesky account from one that was never connected' do
    enable_atproto!(user)
    identity_for(user, status: 'disconnected')

    with_atproto_client do
      entry = ExternalServices::Bluesky.catalog_entry_for(user)
      card = ExternalServices::Bluesky.connections_for(user).first

      expect(entry.configured?).to be(true)
      expect(entry.action_label).to eq(I18n.t('external_services.actions.bluesky.manage'))
      expect(card.status).to eq(:disconnected)
      expect(card.status_label).to eq(I18n.t('external_bridge.atproto.status.disconnected'))
    end
  end
end
