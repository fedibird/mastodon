# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::KeywordSubscribesController, type: :controller do
  render_views

  let(:user)   { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token)  { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:scopes) { 'read:follows write:follows' }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'POST #create' do
    it 'accepts and returns both matching options' do
      post :create, params: { name: 'both', keyword: 'foo', match_hashtags: true, match_urls: true }

      expect(response).to have_http_status(200)
      expect(body_as_json[:match_hashtags]).to be true
      expect(body_as_json[:match_urls]).to be true
      expect(KeywordSubscribe.find(body_as_json[:id]).match_urls).to be true
    end

    it 'leaves both matching options off by default' do
      post :create, params: { name: 'plain', keyword: 'foo' }

      expect(body_as_json[:match_hashtags]).to be false
      expect(body_as_json[:match_urls]).to be false
    end
  end

  describe 'PUT #update' do
    it 'updates both matching options' do
      subscription = KeywordSubscribe.create!(account: user.account, name: 'plain', keyword: 'foo')

      put :update, params: { id: subscription.id, match_hashtags: true, match_urls: true }

      expect(response).to have_http_status(200)
      expect(subscription.reload.match_hashtags).to be true
      expect(subscription.match_urls).to be true
    end
  end

  describe 'GET #index' do
    it 'exposes both matching options' do
      KeywordSubscribe.create!(account: user.account, name: 'tagged', keyword: 'foo', match_hashtags: true)

      get :index

      expect(response).to have_http_status(200)
      expect(body_as_json.first[:match_hashtags]).to be true
      expect(body_as_json.first[:match_urls]).to be false
    end
  end
end
