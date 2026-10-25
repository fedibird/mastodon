# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Fedibird::Preferences::SchemaController, type: :controller do
  render_views

  def authorize(owner, scopes)
    token = Fabricate(:accessible_access_token, resource_owner_id: owner&.id, scopes: scopes)
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'GET #show' do
    let(:user) { Fabricate(:user, locale: 'ja') }

    it 'returns static metadata for the published keys' do
      authorize(user, 'read:preferences')
      get :show

      expect(response).to have_http_status(200)
      expect(response.headers['Cache-Control']).to eq 'private, no-store'
      body = body_as_json
      expect(body[:version]).to eq 1
      keys = body[:schema].map { |item| item[:key] }
      expect(keys).to eq %w(
        user.default_privacy
        user.default_sensitive
        user.default_language
        user.show_translation_bar
        user.translation_preferred_mode
        user.new_features_policy
        user.content_font_size
        user.info_font_size
        user.reduce_motion
        user.emoji_reaction_fallback_policy
        user.preferred_posting_language
      )
      privacy = body[:schema].find { |item| item[:key] == 'user.default_privacy' }
      expect(privacy[:allowed_values]).to eq Status.selectable_visibilities
      expect(privacy[:allowed_values]).not_to include('direct', 'limited')
      expect(privacy[:dependencies]).to eq ['account.locked']
      mode = body[:schema].find { |item| item[:key] == 'user.translation_preferred_mode' }
      expect(mode[:allowed_values]).to eq %w(translated bilingual both)
      expect(mode[:allowed_values]).not_to include('original')
      preferred = body[:schema].find { |item| item[:key] == 'user.preferred_posting_language' }
      expect(preferred[:write_policy]).to eq 'read_only'
      fallback = body[:schema].find { |item| item[:key] == 'user.emoji_reaction_fallback_policy' }
      expect(fallback[:write_policy]).to eq 'read_only'
      expect(fallback[:category]).to eq 'safety'
      expect(fallback[:allowed_values]).to eq %w(allow ask deny)
      expect(preferred[:configured_type]).to be_nil
      font = body[:schema].find { |item| item[:key] == 'user.content_font_size' }
      expect(font[:ui_range]).to eq(min: 10, max: 20, step: nil)
      expect(font[:public_type]).to eq ['integer']
      expect(font[:legacy_formats]).to eq ['numeric_string']
      expect(font[:apply_hint]).to eq 'live'
      expect(body[:schema].find { |item| item[:key] == 'user.info_font_size' }[:apply_hint]).to eq 'live'
      expect(body[:schema].find { |item| item[:key] == 'user.reduce_motion' }[:apply_hint]).to eq 'live'
      expect(response.body).not_to include('source_refs')
      expect(response.body).not_to include('app/models')
      expect(response.body).not_to include(user.account.username)
    end

    it 'is the same document for another signed-in user' do
      other = Fabricate(:user, locale: 'de')
      authorize(user, 'read')
      get :show
      first = response.body
      authorize(other, 'read:preferences')
      get :show

      expect(response.body).to eq first
    end

    it 'rejects read:accounts' do
      authorize(user, 'read:accounts')
      get :show

      expect(response).to have_http_status(403)
    end

    it 'rejects client credentials' do
      authorize(nil, 'read:preferences')
      get :show

      expect(response).to have_http_status(422)
    end
  end
end
