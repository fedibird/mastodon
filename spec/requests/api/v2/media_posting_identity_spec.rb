# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Media API sender identity' do
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
  end
end
