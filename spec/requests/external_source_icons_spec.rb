# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External source icon delivery' do
  let(:source) { icon_source }

  before { Setting.external_bridge_rss = true }

  it 'redirects to the stored copy for the exact fingerprint, publicly cacheable' do
    store_icon!(source)

    get "/external_source_icons/#{source.id}/#{source.icon_fingerprint}"

    expect(response).to have_http_status(302)
    expect(response.location).to include(File.basename(source.icon.path(:original), '.webp')).or include('/external_sources/')
    expect(response.location).not_to include('cdn.example')
    expect(response.headers['Cache-Control']).to include('public')
  end

  it 'is the address the presentation returns, never the original feed image URL' do
    store_icon!(source)

    url = ExternalBridge::RSS::Icon::Delivery.url(source)

    expect(url).to end_with("/external_source_icons/#{source.id}/#{source.icon_fingerprint}")
    expect(url).not_to include('cdn.example')
  end

  it 'is a 404 for the wrong fingerprint, an unknown source, and a source without an icon' do
    store_icon!(source)
    bare = icon_source(canonical_key: 'https://example.com/bare.xml')

    get "/external_source_icons/#{source.id}/#{'0' * 64}"
    expect(response).to have_http_status(404)

    get "/external_source_icons/0/#{source.icon_fingerprint}"
    expect(response).to have_http_status(404)

    get "/external_source_icons/#{bare.id}/#{source.icon_fingerprint}"
    expect(response).to have_http_status(404)

    stub_webpacker_manifest
    get "/external_source_icons/#{source.id}/not-a-fingerprint"
    expect(response).to have_http_status(404)
  end

  it 'stops resolving the old address once the icon is replaced' do
    store_icon!(source)
    old = source.icon_fingerprint
    source.update!(icon_next_check_at: 1.minute.ago)
    stub_icon('https://cdn.example/stored.png', bytes: icon_image('png', 80, 80, [0, 0, 255]))
    ExternalBridge::RSS::Icon::RefreshSource.new.call(source.id)

    get "/external_source_icons/#{source.id}/#{old}"
    expect(response).to have_http_status(404)

    get "/external_source_icons/#{source.id}/#{source.reload.icon_fingerprint}"
    expect(response).to have_http_status(302)
  end
end
