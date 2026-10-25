# frozen_string_literal: true

# The examples share one fixture matrix.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

RSpec.describe 'Stored feed icon in the owner REST extension' do
  let(:owner) { Fabricate(:user, account: Fabricate(:account, username: 'iconowner', display_name: 'Owner Face')) }
  let(:stranger) { Fabricate(:user) }
  let(:owner_headers) { auth_headers_for(owner, 'read:statuses write:statuses') }
  let(:bundle) { external_project_for(owner, body: 'Icon article') }
  let(:status) { bundle[:status] }

  before { Setting.external_bridge_rss = true }

  def presentation_for(headers)
    get "/api/v1/statuses/#{status.id}", headers: headers
    expect(response).to have_http_status(200)
    body_as_json[:fedibird_external][:presentation]
  end

  it 'is nil until an icon is stored, then fills icon_url for projections that already existed' do
    expect(presentation_for(owner_headers)[:icon_url]).to be_nil

    store_icon!(bundle[:source])

    presentation = presentation_for(owner_headers)
    expect(presentation[:icon_url]).to end_with("/external_source_icons/#{bundle[:source].id}/#{bundle[:source].icon_fingerprint}")
    expect(presentation[:thumbnail_url]).to be_nil
  end

  it 'leaves the real account, authorization, and legacy fields unchanged' do
    store_icon!(bundle[:source])

    get "/api/v1/statuses/#{status.id}", headers: owner_headers

    expect(body_as_json[:account]).to include(id: owner.account_id.to_s, username: 'iconowner', display_name: 'Owner Face')
    expect(body_as_json[:visibility]).to eq 'direct'
    expect(body_as_json[:visibility_ex]).to eq 'external'
    expect(body_as_json[:fedibird_external]).to include(protocol: 'rss', interaction: 'local_only')
    expect(body_as_json[:fedibird_external][:presentation]).to include(kind: 'external_source', name: 'Public feed', source_url: 'https://example.com')
  end

  it 'does not give another user the status, and so not the icon either' do
    store_icon!(bundle[:source])

    get "/api/v1/statuses/#{status.id}", headers: auth_headers_for(stranger, 'read:statuses')

    expect(response).to have_http_status(404)
    expect(response.body).not_to include('external_source_icons')
  end

  it 'never exposes the original image URL or the actor avatar URL' do
    store_icon!(bundle[:source], url: 'https://cdn.example/original-secret-name.png')
    actor = ExternalActor.create!(protocol: 'rss', native_id: bundle[:source].canonical_key, avatar_remote_url: 'https://tracker.example/avatar.png')
    bundle[:resource].update!(external_actor: actor)

    get "/api/v1/statuses/#{status.id}", headers: owner_headers

    expect(response.body).not_to include('original-secret-name')
    expect(response.body).not_to include('tracker.example')
  end

  describe 'subscription list' do
    it 'carries icon_url for the owner and nil when none is stored' do
      source = icon_source(canonical_key: 'https://example.com/list.xml')
      subscription = icon_subscriber(source, owner)

      get '/api/v1/external_bridge/rss/subscriptions', headers: owner_headers
      expect(response).to have_http_status(200)
      expect(body_as_json.first[:source]).to include(url: source.canonical_key, icon_url: nil)

      store_icon!(source)
      get '/api/v1/external_bridge/rss/subscriptions', headers: owner_headers
      expect(body_as_json.first[:source][:icon_url]).to end_with("/external_source_icons/#{source.id}/#{source.icon_fingerprint}")
      expect(body_as_json.first[:id]).to eq subscription.id.to_s
    end

    it 'does not list another user subscription' do
      source = icon_source(canonical_key: 'https://example.com/list.xml')
      icon_subscriber(source, owner)
      store_icon!(source)

      get '/api/v1/external_bridge/rss/subscriptions', headers: auth_headers_for(stranger, 'read:statuses')

      expect(body_as_json).to eq []
    end
  end
end
