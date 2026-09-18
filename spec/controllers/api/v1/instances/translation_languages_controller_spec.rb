# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Instances::TranslationLanguagesController, type: :controller do
  render_views

  describe 'GET #show' do
    it 'returns http success without an OAuth token' do
      get :show

      expect(response).to have_http_status(200)
    end

    it 'returns an empty language matrix' do
      get :show

      expect(body_as_json).to eq({})
    end

    it 'sets public cache headers' do
      get :show

      expect(response.cache_control[:public]).to be true
      expect(response.cache_control[:max_age]).to eq(1.day.to_i)
    end
  end
end
