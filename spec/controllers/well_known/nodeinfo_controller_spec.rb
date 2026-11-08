# frozen_string_literal: true

require 'rails_helper'

describe WellKnown::NodeInfoController, type: :controller do
  render_views

  describe 'GET #index' do
    it 'returns json document pointing to node info' do
      get :index

      expect(response).to have_http_status(200)
      expect(response.media_type).to eq 'application/json'

      json = body_as_json

      expect(json[:links]).to be_an Array
      expect(json[:links][0][:rel]).to eq 'http://nodeinfo.diaspora.software/ns/schema/2.0'
      expect(json[:links][0][:href]).to include 'nodeinfo/2.0'
    end
  end

  describe 'GET #show' do
    it 'returns json document with node info properties' do
      get :show

      expect(response).to have_http_status(200)
      expect(response.media_type).to eq 'application/json'

      json = body_as_json

      expect(json[:version]).to eq '2.0'
      expect(json[:usage]).to be_a Hash
      expect(json[:software]).to be_a Hash
      expect(json[:software][:name]).to eq 'fedibird'
      expect(json[:software][:version]).to eq '0.1'
      expect(json[:metadata][:upstream]).to eq(name: 'mastodon', version: '4.2.13')
      features = json.dig(:metadata, :fedibird, :activitypub, :supported)
      expect(features).to include('emoji_react', 'note_references', 'legacy_quote_uri', 'searchable_by', 'group_actor')
      expect(json.dig(:metadata, :fedibird, :schemaVersion)).to eq(1)
      expect(json[:metadata][:fedibird]).not_to have_key(:rest)
      expect(json[:protocols]).to be_an Array
      expect(json[:services]).to eq(outbound: [], inbound: [])
    end
  end
end
