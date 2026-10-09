# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::StatusesController, type: :controller do
  render_views

  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:statuses') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'POST #create sender identity' do
    it 'posts as the authenticated account when the identity is omitted' do
      post :create, params: { status: 'Hello world' }

      status = user.account.statuses.last

      expect(response).to have_http_status(200)
      expect(status.text).to eq 'Hello world'
      expect(status.account_id).to eq user.account.id
    end

    it 'posts as the authenticated account when the identity matches' do
      post :create, params: { status: 'Hello world', posting_identity_id: "local:#{user.account.id}" }

      status = user.account.statuses.last

      expect(response).to have_http_status(200)
      expect(status.text).to eq 'Hello world'
      expect(status.account_id).to eq user.account.id
    end

    it 'rejects a client account_id as a Fedibird extension and does not post as another identity' do
      other = Fabricate(:account, username: 'bob')

      expect do
        post :create, params: { status: 'Stolen', account_id: other.id, posting_identity_id: "local:#{other.id}" }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)
      expect(other.statuses).to be_empty
      expect(user.account.statuses).to be_empty

      expect do
        post :create, params: { status: 'Stolen', posting_identity_id: "local:#{other.id}" }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)

      expect do
        post :create, params: { status: 'Stolen', account_id: user.account.id }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)
    end

    it 'does not post when the named identity is not allowed to post' do
      user.settings.disable_post = true

      expect do
        post :create, params: { status: 'Nope', posting_identity_id: "local:#{user.account.id}" }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)
    end
  end
end
