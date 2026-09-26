# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V2::InstancesController, type: :controller do
  render_views

  before do
    stub_webpacker_manifest
  end

  describe 'GET #show' do
    it 'returns http success' do
      get :show

      expect(response).to have_http_status(200)
    end

    it 'includes the filter_v2 capability' do
      get :show

      expect(JSON.parse(response.body)['fedibird_capabilities']).to include('filter_v2')
    end

    it 'returns the configured status page URL' do
      previous = Setting.status_page_url
      Setting.status_page_url = 'https://status.example.com'

      get :show

      expect(JSON.parse(response.body).dig('configuration', 'urls', 'status')).to eq 'https://status.example.com'
    ensure
      Setting.status_page_url = previous
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
