# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Instances::LanguagesController, type: :controller do
  render_views

  describe 'GET #show' do
    it 'returns http success without an OAuth token' do
      get :show

      expect(response).to have_http_status(200)
    end

    it 'returns a JSON array of supported languages' do
      get :show
      json = body_as_json

      expect(json).to be_an(Array)
      expect(json.pluck(:code)).to match_array(LanguagesHelper::SUPPORTED_LOCALES.keys.map(&:to_s))
    end

    it 'returns Japanese as an English name without native_name' do
      get :show
      json = body_as_json
      japanese = json.find { |language| language[:code] == 'ja' }

      expect(japanese).to eq(code: 'ja', name: 'Japanese')
      expect(json).to all(include(:code, :name))
      expect(json).to all(satisfy { |language| !language.key?(:native_name) })
    end
  end
end
