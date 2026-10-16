# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Boost notification settings API', type: :request do

  let(:user) { Fabricate(:user) }
  let(:target) { Fabricate(:user).account }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:follows write:follows') }

  before do
    allow(LocalNotificationWorker).to receive(:perform_async)
  end

  [false, true].each do |locked|
    context "with locked=#{locked}" do
      before { target.update!(locked: locked) }

      def relationship
        Follow.find_by(account: user.account, target_account: target) || FollowRequest.find_by!(account: user.account, target_account: target)
      end

      it 'defaults to false in both follow and relationships responses' do
        post "/api/v1/accounts/#{target.id}/follow", headers: { 'Authorization' => "Bearer #{token.token}" }, params: { id: target.id }
        expect(response).to have_http_status(:ok)
        expect(body_as_json[:notifying_reblogs]).to be false
        expect(relationship.notify_reblogs).to be false
        get '/api/v1/accounts/relationships', headers: { 'Authorization' => "Bearer #{token.token}" }, params: { id: [target.id] }
        expect(body_as_json.first[:notifying_reblogs]).to be false
      end

      it 'keeps home delivery when only notification settings are updated' do
        allow(UnmergeWorker).to receive(:perform_async)
        post "/api/v1/accounts/#{target.id}/follow", headers: { 'Authorization' => "Bearer #{token.token}" }, params: { delivery: true }
        post "/api/v1/accounts/#{target.id}/follow", headers: { 'Authorization' => "Bearer #{token.token}" }, params: { notify_reblogs: true }
        expect(relationship.delivery).to be true
        expect(UnmergeWorker).not_to have_received(:perform_async)
      end

      it 'enables, preserves, and explicitly disables opt-in without changing other settings' do
        post "/api/v1/accounts/#{target.id}/follow", headers: { 'Authorization' => "Bearer #{token.token}" }, params: { id: target.id, notify: true, reblogs: false, delivery: false, languages: ['ja'] }
        get '/api/v1/accounts/relationships', headers: { 'Authorization' => "Bearer #{token.token}" }, params: { id: [target.id] }
        post "/api/v1/accounts/#{target.id}/follow", headers: { 'Authorization' => "Bearer #{token.token}" }, params: { id: target.id, notify_reblogs: true }
        expect(body_as_json[:notifying_reblogs]).to be true
        expect(body_as_json[:notifying]).to be true
        expect(body_as_json[:showing_reblogs]).to be false
        expect(relationship.delivery).to be false
        expect(relationship.languages).to eq ['ja']
        post "/api/v1/accounts/#{target.id}/follow", headers: { 'Authorization' => "Bearer #{token.token}" }, params: { id: target.id }
        expect(body_as_json[:notifying_reblogs]).to be true
        get '/api/v1/accounts/relationships', headers: { 'Authorization' => "Bearer #{token.token}" }, params: { id: [target.id] }
        expect(body_as_json.first[:notifying_reblogs]).to be true
        post "/api/v1/accounts/#{target.id}/follow", headers: { 'Authorization' => "Bearer #{token.token}" }, params: { id: target.id, notify_reblogs: false }
        expect(body_as_json[:notifying_reblogs]).to be false
        expect(relationship.notify).to be true
      end
    end
  end
end
