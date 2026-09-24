# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::TrendsController, type: :controller do
  render_views

  describe 'GET #index' do
    before do
      Setting.trends = true
      Fabricate.times(10, :tag, trendable: true).each_with_index do |tag, index|
        redis.zadd('trending_tags:allowed', index + 1, tag.id)
      end
      get :index
    end

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end
  end
end
