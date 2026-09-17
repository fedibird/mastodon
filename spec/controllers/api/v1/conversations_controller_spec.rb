require 'rails_helper'

RSpec.describe Api::V1::ConversationsController, type: :controller do
  render_views

  let!(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:other) { Fabricate(:user, account: Fabricate(:account, username: 'bob')) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'GET #index' do
    let(:scopes) { 'read:statuses' }

    before do
      PostStatusService.new.call(other.account, text: 'Hey @alice', visibility: 'direct')
    end

    it 'returns http success' do
      get :index
      expect(response).to have_http_status(200)
    end

    it 'returns pagination headers' do
      get :index, params: { limit: 1 }
      expect(response.headers['Link'].links.size).to eq(2)
    end

    it 'returns conversations' do
      get :index
      json = body_as_json
      expect(json.size).to eq 1
    end
  end

  describe 'POST #read' do
    let(:scopes) { 'write:conversations' }
    let(:conversation) { AccountConversation.find_by!(account: user.account) }

    before do
      PostStatusService.new.call(other.account, text: 'Hey @alice', visibility: 'direct')
    end

    it 'marks the conversation as read' do
      expect(conversation.unread).to be true

      post :read, params: { id: conversation.id }

      expect(response).to have_http_status(200)
      expect(conversation.reload.unread).to be false
      expect(body_as_json[:unread]).to be false
    end
  end

  describe 'POST #unread' do
    let(:scopes) { 'write:conversations' }
    let(:conversation) { AccountConversation.find_by!(account: user.account) }

    before do
      PostStatusService.new.call(other.account, text: 'Hey @alice', visibility: 'direct')
    end

    it 'marks the conversation as unread' do
      conversation.update!(unread: false)

      post :unread, params: { id: conversation.id }

      expect(response).to have_http_status(200)
      expect(conversation.reload.unread).to be true
      expect(body_as_json[:unread]).to be true
    end

    it 'returns http not found for another account conversation' do
      other_conversation = AccountConversation.find_by!(account: other.account)

      post :unread, params: { id: other_conversation.id }

      expect(response).to have_http_status(404)
      expect(other_conversation.reload.unread).to be false
    end

    context 'without a token' do
      before do
        allow(controller).to receive(:doorkeeper_token).and_return(nil)
      end

      it 'returns http unauthorized' do
        post :unread, params: { id: conversation.id }

        expect(response).to have_http_status(401)
      end
    end

    context 'with insufficient scope' do
      let(:scopes) { 'read:statuses' }

      it 'returns http forbidden' do
        post :unread, params: { id: conversation.id }

        expect(response).to have_http_status(403)
        expect(conversation.reload.unread).to be true
      end
    end
  end
end
