# frozen_string_literal: true

require 'rails_helper'

describe Settings::ExternalServices::RSSController do
  render_views

  let(:user) { Fabricate(:user, password: '123456789') }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }

  before do
    sign_in user, scope: :user
    stub_webpacker_manifest
    enable_external_bridge_rss!(user)
  end

  def feed_icons(document)
    document.css('.external-service-feed__icon')
  end

  it 'draws the stored icon over the default RSS icon for a feed that has one' do
    source = icon_source(canonical_key: 'https://example.com/with.xml')
    ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    store_icon!(source)

    get :show, session: challenge

    icon = feed_icons(Nokogiri::HTML(response.body)).first
    expect(icon['aria-hidden']).to eq 'true'
    expect(icon.at_css('img.external-service-feed__icon-default')).to be_present
    image = icon.at_css('img.external-service-feed__icon-image')
    expect(image['src']).to end_with("/external_source_icons/#{source.id}/#{source.icon_fingerprint}")
    expect(image['alt']).to eq ''
    expect(image['referrerpolicy']).to eq 'no-referrer'
    expect(response.body).not_to include('cdn.example')
  end

  it 'shows only the default RSS icon while no icon is stored or after a failure' do
    pending_source = icon_source(canonical_key: 'https://example.com/none.xml')
    failed_source = icon_source(canonical_key: 'https://example.com/failed.xml', icon_error_code: 'http_404', icon_failure_count: 2)
    [pending_source, failed_source].each { |source| ExternalSubscription.create!(user: user, external_source: source, state: 'active') }

    get :show, session: challenge

    icons = feed_icons(Nokogiri::HTML(response.body))
    expect(icons.size).to eq 2
    icons.each do |icon|
      expect(icon.at_css('img.external-service-feed__icon-default')).to be_present
      expect(icon.at_css('img.external-service-feed__icon-image')).to be_nil
    end
  end

  it 'does not show another user feed icon' do
    source = icon_source(canonical_key: 'https://example.com/theirs.xml', title: 'Their private pick')
    ExternalSubscription.create!(user: Fabricate(:user), external_source: source, state: 'active')
    store_icon!(source)

    get :show, session: challenge

    expect(response.body).not_to include('Their private pick')
    expect(response.body).not_to include('external_source_icons')
  end
end
