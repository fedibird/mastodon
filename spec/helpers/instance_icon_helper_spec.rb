# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InstanceHelper, type: :helper do
  before { Rails.cache.clear }

  describe 'custom icons' do
    it 'returns upload URLs and suppresses the mask icon when an app icon exists' do
      favicon = SiteUpload.new(var: 'favicon')
      app_icon = SiteUpload.new(var: 'app_icon')
      allow(favicon).to receive_message_chain(:file, :url).with('16').and_return('/system/favicon-16.png')
      allow(app_icon).to receive_message_chain(:file, :url).with('180').and_return('/system/app-icon-180.png')
      allow(Rails.cache).to receive(:fetch).and_call_original
      allow(Rails.cache).to receive(:fetch).with('site_uploads/favicon').and_yield
      allow(Rails.cache).to receive(:fetch).with('site_uploads/app_icon').and_yield
      allow(SiteUpload).to receive(:find_by).with(var: 'favicon').and_return(favicon)
      allow(SiteUpload).to receive(:find_by).with(var: 'app_icon').and_return(app_icon)

      expect(helper.favicon_path(16)).to eq '/system/favicon-16.png'
      expect(helper.app_icon_path(180)).to eq '/system/app-icon-180.png'
      expect(helper.use_mask_icon?).to be false
    end

    it 'falls back when no custom icons are configured' do
      allow(SiteUpload).to receive(:find_by).and_return(nil)

      expect(helper.favicon_path(16)).to be_nil
      expect(helper.app_icon_path(192)).to be_nil
      expect(helper.use_mask_icon?).to be true
    end
  end

  describe 'default_favicon_path' do
    it 'returns the standard Fedibird png favicons' do
      expect(helper.default_favicon_path(16)).to eq '/icons/favicon-16x16.png'
      expect(helper.default_favicon_path(32)).to eq '/icons/favicon-32x32.png'
      expect(helper.default_favicon_path(48)).to eq '/icons/favicon-48x48.png'
    end
  end
end
