# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ManifestSerializer do
  before { Rails.cache.clear }

  it 'lists every generated Android size for a custom app icon' do
    app_icon = SiteUpload.new(var: 'app_icon')
    allow(app_icon).to receive_message_chain(:file, :url) { |size| "/system/app-icon-#{size}.png" }
    allow(Rails.cache).to receive(:fetch).with('site_uploads/app_icon').and_yield
    allow(SiteUpload).to receive(:find_by).with(var: 'app_icon').and_return(app_icon)

    icons = described_class.new(InstancePresenter.new).icons
    icons_by_size = icons.index_by { |icon| icon[:sizes] }

    expect(icons.map { |icon| icon[:sizes] }).to eq(SiteUpload::ANDROID_ICON_SIZES.map { |size| "#{size}x#{size}" })
    expect(icons_by_size['192x192'][:src]).to include('/system/app-icon-192.png')
    expect(icons_by_size['512x512'][:src]).to include('/system/app-icon-512.png')
    expect(icons).to all(include(type: 'image/png', purpose: 'any maskable'))
  end

  it 'uses the existing Fedibird icon when no custom app icon is configured' do
    allow(SiteUpload).to receive(:find_by).with(var: 'app_icon').and_return(nil)

    icons = described_class.new(InstancePresenter.new).icons

    expect(icons).to contain_exactly(include(sizes: '192x192', src: include('/android-chrome-192x192.png')))
  end
end
