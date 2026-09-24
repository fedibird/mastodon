# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Instances::TranslationLanguagesController, type: :controller do
  render_views

  describe 'GET #show' do
    it 'returns http success without an OAuth token' do
      get :show

      expect(response).to have_http_status(200)
    end

    it 'advertises translation on the v2 instance configuration' do
      serializer = REST::InstanceSerializer.new(InstancePresenter.new)

      allow(TranslationService).to receive(:configured?).and_return(false)
      expect(serializer.configuration.dig(:translation, :enabled)).to be false

      allow(TranslationService).to receive(:configured?).and_return(true)
      expect(serializer.configuration.dig(:translation, :enabled)).to be true
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

    it 'returns cached provider languages and exposes undetermined sources as und' do
      languages = { 'ja' => ['en'], nil => ['en', 'ja'] }
      backend = instance_double(TranslationService::DeepL, languages: languages)
      allow(TranslationService).to receive(:configured?).and_return(true)
      allow(TranslationService).to receive(:configured).and_return(backend)
      Rails.cache.clear

      get :show
      get :show

      expect(body_as_json[:ja]).to eq ['en']
      expect(body_as_json[:und]).to eq ['en', 'ja']
      expect(backend).to have_received(:languages).once
    end
  end
end
