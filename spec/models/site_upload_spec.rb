# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteUpload, type: :model do
  describe 'icon styles' do
    it 'generates png favicon sizes and the combined app icon sizes' do
      expect(described_class::STYLES[:favicon].keys.map(&:to_s)).to eq %w(16 32 48)
      expect(described_class::STYLES[:favicon].values).to all(include(format: 'png'))
      expect(described_class::STYLES[:app_icon].keys.map(&:to_s)).to match_array(described_class::APP_ICON_SIZES.map(&:to_s))
      expect(described_class::STYLES[:app_icon].values).to all(include(format: 'png'))
      expect(described_class::APP_ICON_SIZES).to include(*described_class::APPLE_ICON_SIZES, *described_class::ANDROID_ICON_SIZES)
    end
  end

  describe '#cache_key' do
    let(:site_upload) { SiteUpload.new(var: 'var') }

    it 'returns cache_key' do
      expect(site_upload.cache_key).to eq 'site_uploads/var'
    end
  end
end
