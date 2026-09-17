# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Familiar followers API' do
  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:alice) { user.account }
  let(:bob) { Fabricate(:user, account: Fabricate(:account, username: 'bob')).account }
  let(:carol) { Fabricate(:user, account: Fabricate(:account, username: 'carol')).account }
  let(:dave) { Fabricate(:user, account: Fabricate(:account, username: 'dave')).account }
  let(:eve) { Fabricate(:user, account: Fabricate(:account, username: 'eve')).account }
  let(:frank) { Fabricate(:user, account: Fabricate(:account, username: 'frank')).account }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:scopes) { 'read:follows' }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

  def familiar_account_ids_for(target)
    result = body_as_json.find { |entry| result_id(entry) == target.id.to_s }
    Array(result && result[:accounts]).map { |account| account[:id] }
  end

  def result_id(entry)
    entry[:id]
  end

  shared_examples 'forbidden for wrong scope' do |wrong_scope|
    let(:scopes) { wrong_scope }

    it 'returns http forbidden' do
      subject

      expect(response).to have_http_status(403)
    end
  end

  describe 'GET /api/v1/accounts/familiar_followers' do
    before do
      alice.follow!(bob)
      alice.follow!(frank)
      bob.follow!(carol)
      dave.follow!(carol)
      frank.follow!(eve)
    end

    context 'with a single target' do
      subject { get '/api/v1/accounts/familiar_followers', headers: headers, params: { id: [carol.id] } }

      it_behaves_like 'forbidden for wrong scope', 'read:accounts'

      it 'returns only accounts the current user also follows' do
        subject

        expect(response).to have_http_status(200)
        expect(body_as_json.size).to eq(1)
        expect(body_as_json.first[:id]).to eq(carol.id.to_s)
        expect(familiar_account_ids_for(carol)).to include(bob.id.to_s)
        expect(familiar_account_ids_for(carol)).to_not include(dave.id.to_s)
        expect(familiar_account_ids_for(carol)).to_not be_empty
      end
    end

    context 'with the encompassing read scope' do
      let(:scopes) { 'read' }

      it 'returns http success' do
        get '/api/v1/accounts/familiar_followers', headers: headers, params: { id: [carol.id] }

        expect(response).to have_http_status(200)
        expect(body_as_json).to_not be_empty
      end
    end

    context 'with multiple targets' do
      it 'preserves request order and separate account lists' do
        get '/api/v1/accounts/familiar_followers', headers: headers, params: { id: [carol.id, eve.id] }

        expect(response).to have_http_status(200)
        expect(body_as_json.map { |entry| result_id(entry) }).to eq([carol.id.to_s, eve.id.to_s])
        expect(familiar_account_ids_for(carol)).to include(bob.id.to_s)
        expect(familiar_account_ids_for(carol)).to_not include(frank.id.to_s)
        expect(familiar_account_ids_for(eve)).to include(frank.id.to_s)
        expect(familiar_account_ids_for(eve)).to_not include(bob.id.to_s)
      end
    end

    context 'when the requested account hides collections' do
      before do
        carol.update!(hide_collections: true)
      end

      it 'keeps the result with an empty accounts list' do
        get '/api/v1/accounts/familiar_followers', headers: headers, params: { id: [carol.id] }

        expect(response).to have_http_status(200)
        expect(body_as_json.size).to eq(1)
        expect(body_as_json.first[:id]).to eq(carol.id.to_s)
        expect(body_as_json.first[:accounts]).to eq([])
      end
    end

    context 'when a familiar follower hides collections' do
      before do
        bob.update!(hide_collections: true)
      end

      it 'omits that familiar follower' do
        get '/api/v1/accounts/familiar_followers', headers: headers, params: { id: [carol.id] }

        expect(response).to have_http_status(200)
        expect(body_as_json.first[:id]).to eq(carol.id.to_s)
        expect(familiar_account_ids_for(carol)).to_not include(bob.id.to_s)
      end
    end

    context 'when the requested account hides their network' do
      before do
        carol.user.settings.hide_network = true
      end

      it 'keeps the result with an empty accounts list' do
        get '/api/v1/accounts/familiar_followers', headers: headers, params: { id: [carol.id] }

        expect(response).to have_http_status(200)
        expect(body_as_json.size).to eq(1)
        expect(body_as_json.first[:id]).to eq(carol.id.to_s)
        expect(body_as_json.first[:accounts]).to eq([])
      end
    end

    context 'when a familiar follower hides their network' do
      before do
        bob.user.settings.hide_network = true
      end

      it 'omits that familiar follower' do
        get '/api/v1/accounts/familiar_followers', headers: headers, params: { id: [carol.id] }

        expect(response).to have_http_status(200)
        expect(body_as_json.first[:id]).to eq(carol.id.to_s)
        expect(familiar_account_ids_for(carol)).to_not include(bob.id.to_s)
      end
    end

    context 'with a missing and a suspended account id' do
      let(:suspended) { Fabricate(:account, username: 'suspended', suspended: true) }

      it 'omits those ids without error' do
        get '/api/v1/accounts/familiar_followers', headers: headers, params: { id: [carol.id, 0, suspended.id] }

        expect(response).to have_http_status(200)
        expect(body_as_json.map { |entry| result_id(entry) }).to eq([carol.id.to_s])
      end
    end

    context 'with duplicate ids' do
      it 'returns a single result' do
        get '/api/v1/accounts/familiar_followers', headers: headers, params: { id: [carol.id, carol.id] }

        expect(response).to have_http_status(200)
        expect(body_as_json.size).to eq(1)
        expect(body_as_json.first[:id]).to eq(carol.id.to_s)
      end
    end

    context 'without ids' do
      it 'returns an empty array' do
        get '/api/v1/accounts/familiar_followers', headers: headers

        expect(response).to have_http_status(200)
        expect(body_as_json).to eq([])
      end
    end

    context 'without an oauth token' do
      it 'returns http unauthorized' do
        get '/api/v1/accounts/familiar_followers', params: { id: [carol.id] }

        expect(response).to have_http_status(401)
      end
    end
  end
end
