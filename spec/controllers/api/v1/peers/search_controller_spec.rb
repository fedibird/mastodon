# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Peers::SearchController, type: :controller do
  render_views

  def refresh_instances
    Instance.refresh
  end

  describe 'GET #index' do
    before do
      %w(example.com example.org other.test).each do |domain|
        Fabricate(:account, domain: domain, username: "user-#{domain}")
      end
      11.times do |index|
        Fabricate(:account, domain: "prefix#{index}.example", username: "prefix-#{index}")
      end
      refresh_instances
    end

    it 'returns a normalized prefix match' do
      get :index, params: { q: ' EXAMPLE' }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include('example.com', 'example.org')
      expect(body_as_json).not_to include('other.test')
    end

    it 'returns at most 10 domains' do
      get :index, params: { q: 'prefix' }

      expect(body_as_json.size).to eq 10
    end

    it 'returns an empty array when nothing matches' do
      get :index, params: { q: 'missing.example' }

      expect(body_as_json).to eq []
    end

    it 'returns an empty array for a malformed domain' do
      get :index, params: { q: 'not a domain' }

      expect(response).to have_http_status(200)
      expect(body_as_json).to eq []
    end

    it 'returns 404 when the peers API is disabled' do
      Setting.peers_api_enabled = false

      get :index, params: { q: 'example' }

      expect(response).to have_http_status(404)
    end

    it 'returns 404 in limited federation mode' do
      user = Fabricate(:user)
      token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read')
      allow(controller).to receive(:doorkeeper_token) { token }
      allow(Rails.configuration.x).to receive(:whitelist_mode).and_return(true)

      get :index, params: { q: 'example' }

      expect(response).to have_http_status(404)
    end

    it 'requires authentication in limited federation mode' do
      allow(Rails.configuration.x).to receive(:whitelist_mode).and_return(true)

      get :index, params: { q: 'example' }

      expect(response).to have_http_status(401)
    end

    it 'uses InstancesIndex when Chewy is enabled' do
      results = double('instances query')
      allow(Chewy).to receive(:enabled?).and_return(true)
      allow(InstancesIndex).to receive(:query).and_return(results)
      allow(results).to receive(:limit).with(10).and_return(results)
      allow(results).to receive(:pluck).with(:domain).and_return(['example.com'])

      get :index, params: { q: 'Example' }

      expect(response).to have_http_status(200)
      expect(body_as_json).to eq ['example.com']
      expect(InstancesIndex).to have_received(:query).with(hash_including(function_score: hash_including(query: { prefix: { domain: 'example' } })))
    end
  end
end