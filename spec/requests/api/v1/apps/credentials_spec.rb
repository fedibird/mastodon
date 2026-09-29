# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Credentials' do
  describe 'GET /api/v1/apps/verify_credentials' do
    subject do
      get '/api/v1/apps/verify_credentials', headers: headers
    end

    context 'with an oauth token' do
      let(:application) { Fabricate(:application, scopes: 'read') }
      let(:token)   { Fabricate(:accessible_access_token, application: application, scopes: 'read') }
      let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

      it 'returns the app information correctly', :aggregate_failures do
        subject

        expect(response).to have_http_status(200)
        expect(response.content_type)
          .to start_with('application/json')

        expect(body_as_json).to match(
          a_hash_including(
            id: token.application.id.to_s,
            name: token.application.name,
            website: token.application.website,
            scopes: token.application.scopes.map(&:to_s),
            redirect_uris: token.application.redirect_uris,
            # Deprecated properties as of 4.3:
            redirect_uri: token.application.redirect_uri.split.first,
            vapid_key: Rails.configuration.x.vapid_public_key
          )
        )
        expect(body_as_json).not_to have_key(:client_id)
        expect(body_as_json).not_to have_key(:client_secret)
        expect(body_as_json).not_to have_key(:client_secret_expires_at)
      end
    end

    context 'with a non-read scoped oauth token' do
      let(:application) { Fabricate(:application, scopes: 'admin:write') }
      let(:token)   { Fabricate(:accessible_access_token, application: application, scopes: 'admin:write') }
      let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

      it 'returns http success and returns app information' do
        subject

        expect(response).to have_http_status(200)
        expect(response.content_type)
          .to start_with('application/json')

        expect(body_as_json).to match(
          a_hash_including(
            id: token.application.id.to_s,
            name: token.application.name,
            website: token.application.website,
            scopes: token.application.scopes.map(&:to_s),
            redirect_uris: token.application.redirect_uris,
            # Deprecated properties as of 4.3:
            redirect_uri: token.application.redirect_uri.split.first,
            vapid_key: Rails.configuration.x.vapid_public_key
          )
        )
        expect(body_as_json).not_to have_key(:client_id)
        expect(body_as_json).not_to have_key(:client_secret)
        expect(body_as_json).not_to have_key(:client_secret_expires_at)
      end
    end

    context 'without an oauth token' do
      let(:headers) { {} }

      it 'returns http unauthorized' do
        subject

        expect(response).to have_http_status(401)
        expect(response.content_type)
          .to start_with('application/json')
      end
    end

    context 'with a revoked oauth token' do
      let(:application) { Fabricate(:application, scopes: 'read') }
      let(:token)   { Fabricate(:accessible_access_token, application: application, revoked_at: DateTime.now.utc) }
      let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

      it 'returns http authorization error' do
        subject

        expect(response).to have_http_status(401)
        expect(response.content_type)
          .to start_with('application/json')
      end

      it 'returns the error in the json response' do
        subject

        expect(body_as_json).to match(
          a_hash_including(
            error: 'The access token was revoked'
          )
        )
      end
    end

    context 'with an invalid oauth token' do
      let(:application) { Fabricate(:application, scopes: 'read') }
      let(:token)   { Fabricate(:accessible_access_token, application: application) }
      let(:headers) { { 'Authorization' => "Bearer #{token.token}-invalid" } }

      it 'returns http authorization error with json error' do
        subject

        expect(response).to have_http_status(401)
        expect(response.content_type)
          .to start_with('application/json')

        expect(body_as_json).to match(
          a_hash_including(
            error: 'The access token is invalid'
          )
        )
      end
    end
  end
end
