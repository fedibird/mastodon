# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Trends::TagsController, type: :controller do
  render_views

  describe 'GET #index' do
    before do
      Setting.trends = true
      Fabricate.times(3, :tag, trendable: true).each_with_index do |tag, index|
        redis.zadd('trending_tags:allowed', index + 1, tag.id)
      end
    end

    it 'returns http success' do
      get :index

      expect(response).to have_http_status(200)
    end
  end
end
