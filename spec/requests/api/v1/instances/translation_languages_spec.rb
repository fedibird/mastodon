# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Translation languages API' do
  describe 'GET /api/v1/instance/translation_languages' do
    it 'routes to the translation languages endpoint and returns an empty matrix' do
      get '/api/v1/instance/translation_languages'

      expect(response).to have_http_status(200)
      expect(body_as_json).to eq({})
    end
  end
end
