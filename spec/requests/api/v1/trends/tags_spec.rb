# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Trends tags API' do
  let(:tags) { Fabricate.times(3, :tag) }

  before do
    allow(TrendingTags).to receive(:get).and_return(tags)
  end

  describe 'GET /api/v1/trends/tags' do
    it 'returns http success without an OAuth token' do
      get '/api/v1/trends/tags'

      expect(response).to have_http_status(200)
      expect(body_as_json).to be_an(Array)
    end

    it 'passes an explicit limit to TrendingTags' do
      expect(TrendingTags).to receive(:get).with(3).and_return(tags)

      get '/api/v1/trends/tags', params: { limit: 3 }

      expect(response).to have_http_status(200)
    end
  end

  describe 'compatibility with GET /api/v1/trends' do
    it 'returns the same tag list as the legacy endpoint' do
      get '/api/v1/trends'
      old_body = body_as_json

      get '/api/v1/trends/tags'
      new_body = body_as_json

      expect(new_body).to eq(old_body)
    end
  end
end
