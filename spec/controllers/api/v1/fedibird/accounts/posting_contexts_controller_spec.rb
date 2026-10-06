# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Fedibird::Accounts::PostingContextsController do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user) { Fabricate(:user) }
  let(:scopes) { 'read:accounts' }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'GET #show' do # rubocop:disable Metrics/BlockLength
    it 'returns a resolved local group context' do
      account = Fabricate(:account, username: 'group', actor_type: 'Group')

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        schema_version: 1,
        account_id: account.id.to_s,
        status: 'resolved'
      )
      expect(body_as_json[:context][:managed][:mentions].first[:acct]).to eq 'group'
      expect(body_as_json[:discovery]).to eq(
        mechanism: 'built_in',
        adapter: 'fedibird_group',
        authority: 'server'
      )
    end

    it 'returns unsupported for a remote group' do
      account = Fabricate(:account, username: 'group', domain: 'example.com', actor_type: 'Group')

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil
      )
    end

    it 'returns not_applicable for a person' do
      account = Fabricate(:account, username: 'alice')

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        status: 'not_applicable',
        reason: 'not_group',
        context: nil
      )
    end

    it 'returns not found for an unknown account' do
      get :show, params: { account_id: 99_999_999_999 }

      expect(response).to have_http_status(404)
    end

    context 'with the wrong scope' do
      let(:scopes) { 'write:statuses' }

      it 'returns http forbidden' do
        account = Fabricate(:account, username: 'group', actor_type: 'Group')

        get :show, params: { account_id: account.id }

        expect(response).to have_http_status(403)
      end
    end

    context 'without an oauth token' do
      before do
        allow(controller).to receive(:doorkeeper_token) { nil }
      end

      it 'returns http unauthorized' do
        account = Fabricate(:account, username: 'group', actor_type: 'Group')

        get :show, params: { account_id: account.id }

        expect(response).to have_http_status(401)
      end
    end
  end
end
