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
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
