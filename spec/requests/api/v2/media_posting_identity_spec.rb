# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Media API sender identity' do # rubocop:disable Metrics/BlockLength
  let(:user)    { Fabricate(:user) }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:media') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

  describe 'POST /api/v2/media' do
    it 'rejects a client account id before storing media' do
      other = Fabricate(:account)

      post '/api/v2/media', headers: headers, params: {
        account_id: other.id,
        posting_identity_id: "local:#{other.id}",
      }

      expect(response).to have_http_status(403)
      expect(MediaAttachment.where(account: other)).to be_empty
      expect(MediaAttachment.where(account: user.account)).to be_empty
    end

    it 'rejects an identity that is not the authenticated account' do
      other = Fabricate(:account)

      post '/api/v2/media', headers: headers, params: { posting_identity_id: "local:#{other.id}" }

      expect(response).to have_http_status(403)
      expect(MediaAttachment.where(account: other)).to be_empty
    end

    it 'rejects a client account id on its own as a Fedibird extension' do
      other = Fabricate(:account)

      post '/api/v2/media', headers: headers, params: { account_id: other.id }

      expect(response).to have_http_status(403)
      expect(MediaAttachment.where(account: [other, user.account])).to be_empty
    end
  end

  describe 'POST /api/v1/media' do
    it 'rejects another identity before storing media' do
      other = Fabricate(:account)

      post '/api/v1/media', headers: headers, params: { posting_identity_id: "local:#{other.id}" }

      expect(response).to have_http_status(403)
      expect(MediaAttachment.where(account: other)).to be_empty
    end
  end

  describe 'PUT /api/v1/media/:id' do
    let(:media) { Fabricate(:media_attachment, status: nil, account: user.account, description: 'before') }

    it 'updates media when the identity matches or is omitted' do
      put "/api/v1/media/#{media.id}", headers: headers, params: {
        description: 'with identity',
        posting_identity_id: "local:#{user.account.id}",
      }

      expect(response).to have_http_status(200)
      expect(media.reload.description).to eq 'with identity'

      put "/api/v1/media/#{media.id}", headers: headers, params: { description: 'omitted identity' }

      expect(response).to have_http_status(200)
      expect(media.reload.description).to eq 'omitted identity'
    end

    it 'rejects another identity or a client account id without changing the media' do
      other = Fabricate(:account)

      put "/api/v1/media/#{media.id}", headers: headers, params: {
        description: 'stolen',
        posting_identity_id: "local:#{other.id}",
      }

      expect(response).to have_http_status(403)
      expect(media.reload.description).to eq 'before'

      put "/api/v1/media/#{media.id}", headers: headers, params: {
        description: 'stolen',
        account_id: user.account.id,
        thumbnail: fixture_file_upload('attachment.jpg', 'image/jpeg'),
      }

      expect(response).to have_http_status(403)
      expect(media.reload.description).to eq 'before'
    end
  end
end
