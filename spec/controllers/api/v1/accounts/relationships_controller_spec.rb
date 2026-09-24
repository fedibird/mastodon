require 'rails_helper'

describe Api::V1::Accounts::RelationshipsController do
  render_views

  let(:user)  { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:follows') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'GET #index' do
    let(:simon) { Fabricate(:user, email: 'simon@example.com', account: Fabricate(:account, username: 'simon')).account }
    let(:lewis) { Fabricate(:user, email: 'lewis@example.com', account: Fabricate(:account, username: 'lewis')).account }

    before do
      user.account.follow!(simon)
      lewis.follow!(user.account)
    end

    context 'provided only one ID' do
      before do
        get :index, params: { id: simon.id }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'returns JSON with correct data' do
        json = body_as_json

        expect(json).to be_a Enumerable
        expect(json.first[:following]).to be true
        expect(json.first[:followed_by]).to be false
      end
    end

    context 'provided multiple IDs' do
      before do
        get :index, params: { id: [simon.id, lewis.id] }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'returns JSON with correct data' do
        json = body_as_json

        expect(json).to be_a Enumerable
        expect(json.first[:id]).to eq simon.id.to_s
        expect(json.first[:following]).to be true
        expect(json.first[:showing_reblogs]).to be true
        expect(json.first[:followed_by]).to be false
        expect(json.first[:muting]).to be false
        expect(json.first[:requested]).to be false
        expect(json.first[:requested_by]).to be false
        expect(json.first[:domain_blocking]).to be false
        expect(json.first[:languages]).to be_nil

        expect(json.second[:id]).to eq lewis.id.to_s
        expect(json.second[:following]).to be false
        expect(json.second[:showing_reblogs]).to be false
        expect(json.second[:followed_by]).to be true
        expect(json.second[:muting]).to be false
        expect(json.second[:requested]).to be false
        expect(json.second[:requested_by]).to be false
        expect(json.second[:domain_blocking]).to be false
      end

      it 'returns JSON with correct data on cached requests too' do
        get :index, params: { id: [simon.id] }

        json = body_as_json

        expect(json).to be_a Enumerable
        expect(json.first[:following]).to be true
        expect(json.first[:showing_reblogs]).to be true
      end

      it 'returns JSON with correct data after change too' do
        user.account.unfollow!(simon)

        get :index, params: { id: [simon.id] }

        json = body_as_json

        expect(json).to be_a Enumerable
        expect(json.first[:following]).to be false
        expect(json.first[:showing_reblogs]).to be false
      end
    end

    context 'with follow requests' do
      let(:target) { Fabricate(:account, username: 'nina') }

      it 'returns requested_by for an incoming follow request' do
        Fabricate(:follow_request, account: simon, target_account: user.account)

        get :index, params: { id: [simon.id] }

        json = body_as_json

        expect(json.first[:requested_by]).to be true
        expect(json.first[:requested]).to be false
        expect(json.first[:followed_by]).to be false
      end

      it 'returns requested for an outgoing follow request' do
        Fabricate(:follow_request, account: user.account, target_account: target)

        get :index, params: { id: [target.id] }

        json = body_as_json

        expect(json.first[:requested]).to be true
        expect(json.first[:requested_by]).to be false
      end

      it 'invalidates cached requested_by when an incoming follow request is created' do
        get :index, params: { id: [simon.id] }
        expect(body_as_json.first[:requested_by]).to be false

        Fabricate(:follow_request, account: simon, target_account: user.account)

        get :index, params: { id: [simon.id] }

        json = body_as_json

        expect(json.first[:requested_by]).to be true
        expect(json.first[:followed_by]).to be false
      end

      it 'invalidates cached requested_by after the follow request is rejected' do
        follow_request = Fabricate(:follow_request, account: simon, target_account: user.account)

        get :index, params: { id: [simon.id] }
        expect(body_as_json.first[:requested_by]).to be true

        follow_request.reject!

        get :index, params: { id: [simon.id] }
        expect(body_as_json.first[:requested_by]).to be false
      end
    end

    context 'with follow languages' do
      let(:target) { Fabricate(:account, username: 'nina') }

      it 'returns languages for an established follow' do
        user.account.follow!(target, languages: %w(en ja))

        get :index, params: { id: [target.id] }

        expect(body_as_json.first[:languages]).to match_array %w(en ja)
      end

      it 'returns languages for a pending follow request' do
        user.account.request_follow!(target, languages: ['ja'])

        get :index, params: { id: [target.id] }

        json = body_as_json

        expect(json.first[:requested]).to be true
        expect(json.first[:languages]).to eq ['ja']
      end

      it 'returns null languages when there is no restriction' do
        get :index, params: { id: [simon.id] }
        expect(body_as_json.first[:languages]).to be_nil
      end

      it 'invalidates cached languages after the follow is updated' do
        user.account.follow!(target, languages: ['en'])

        get :index, params: { id: [target.id] }
        expect(body_as_json.first[:languages]).to eq ['en']

        user.account.follow!(target, languages: ['ja'])

        get :index, params: { id: [target.id] }
        expect(body_as_json.first[:languages]).to eq ['ja']
      end
    end

    context 'with suspended accounts' do
      let(:carol) { Fabricate(:account, username: 'carol') }

      it 'returns an empty list for a suspended account that is followed' do
        user.account.follow!(simon)
        simon.suspend!

        get :index, params: { id: [simon.id] }

        expect(response).to have_http_status(200)
        expect(body_as_json).to eq []
      end

      it 'returns only active accounts in the requested order' do
        lewis.suspend!

        get :index, params: { id: [simon.id, lewis.id, carol.id] }

        expect(response).to have_http_status(200)
        expect(body_as_json.map { |row| row[:id] }).to eq [simon.id.to_s, carol.id.to_s]
        expect(body_as_json.first[:following]).to be true
        expect(body_as_json.first[:languages]).to be_nil
      end

      it 'returns each active id once' do
        get :index, params: { id: [simon.id, simon.id, lewis.id] }

        expect(body_as_json.map { |row| row[:id] }).to eq [simon.id.to_s, lewis.id.to_s]
      end
    end
  end
end
