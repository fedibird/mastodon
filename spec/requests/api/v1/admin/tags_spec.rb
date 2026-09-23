# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin Tags API' do # rubocop:disable Metrics/BlockLength
  def serializer_keys
    %i(id name url history trendable usable requires_review listable)
  end

  let(:role)    { 'moderator' }
  let(:user)    { user_with_legacy_role_name(role, account: Fabricate(:account, username: 'alice')) }
  let(:scopes)  { 'admin:read admin:write' }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:headers) do
    {
      'Authorization' => "Bearer #{token.token}",
      'Accept' => 'application/json',
    }
  end

  shared_examples 'forbidden for wrong scope' do |wrong_scope|
    let(:scopes) { wrong_scope }

    it 'returns http forbidden' do
      subject

      expect(response).to have_http_status(403)
    end
  end

  shared_examples 'forbidden for wrong role' do |wrong_role|
    let(:role) { wrong_role }

    it 'returns http forbidden' do
      subject

      expect(response).to have_http_status(403)
    end
  end

  describe 'GET /api/v1/admin/tags' do # rubocop:disable Metrics/BlockLength
    subject { get '/api/v1/admin/tags', headers: headers, params: params, as: :json }

    let(:params) { {} }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success for a moderator' do
      subject

      expect(response).to have_http_status(200)
    end

    context 'with admin:read scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http success' do
        subject

        expect(response).to have_http_status(200)
      end
    end

    context 'as an enabled admin' do
      let(:role) { 'admin' }

      it 'returns http success' do
        subject

        expect(response).to have_http_status(200)
      end
    end

    context 'without a token' do
      it 'returns http unauthorized' do
        get '/api/v1/admin/tags', headers: { 'Accept' => 'application/json' }, as: :json

        expect(response).to have_http_status(401)
      end
    end

    context 'when the staff account is disabled' do
      before { user.disable! }

      it 'returns http forbidden for a disabled moderator' do
        subject

        expect(response).to have_http_status(403)
      end

      context 'as a disabled admin' do
        let(:role) { 'admin' }

        it 'returns http forbidden' do
          subject

          expect(response).to have_http_status(403)
        end
      end
    end

    context 'with no tags' do
      before { Tag.delete_all }

      it 'returns an empty array' do
        subject

        expect(response).to have_http_status(200)
        expect(body_as_json).to eq([])
      end
    end

    context 'with tags' do
      before { Tag.delete_all }

      let!(:older) { Fabricate(:tag, name: 'alpha') }
      let!(:newer) { Fabricate(:tag, name: 'beta') }

      it 'returns serialized tags newest first with string ids' do
        subject

        expect(response).to have_http_status(200)
        expect(body_as_json.map { |entry| entry[:id] }).to eq([newer.id.to_s, older.id.to_s])
        expect(body_as_json.first[:id]).to be_a(String)
        expect(body_as_json.first.keys).to contain_exactly(*serializer_keys)
        expect(body_as_json.first).not_to have_key(:following)
      end

      it 'respects the limit parameter' do
        get '/api/v1/admin/tags', headers: headers, params: { limit: 1 }, as: :json

        expect(body_as_json.size).to eq(1)
        expect(body_as_json.first[:id]).to eq(newer.id.to_s)
      end

      it 'sets pagination Link headers' do
        get '/api/v1/admin/tags', headers: headers, params: { limit: 1 }, as: :json

        links = LinkHeader.parse(response.headers['Link'].to_s)
        expect(links.find_link(%w(rel next)).href).to eq api_v1_admin_tags_url(limit: 1, max_id: newer.id)
        expect(links.find_link(%w(rel prev)).href).to eq api_v1_admin_tags_url(limit: 1, min_id: newer.id)
      end

      it 'paginates with max_id' do
        get '/api/v1/admin/tags', headers: headers, params: { max_id: newer.id }, as: :json

        expect(body_as_json.map { |entry| entry[:id] }).to eq([older.id.to_s])
      end

      it 'paginates with since_id' do
        get '/api/v1/admin/tags', headers: headers, params: { since_id: older.id }, as: :json

        expect(body_as_json.map { |entry| entry[:id] }).to eq([newer.id.to_s])
      end

      it 'paginates with min_id' do
        get '/api/v1/admin/tags', headers: headers, params: { min_id: older.id, limit: 2 }, as: :json

        expect(body_as_json.map { |entry| entry[:id] }).to eq([newer.id.to_s])
      end
    end
  end

  describe 'GET /api/v1/admin/tags/:id' do
    subject { get "/api/v1/admin/tags/#{tag.id}", headers: headers, as: :json }

    let!(:tag) { Fabricate(:tag, name: 'foo') }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns the serialized tag for a moderator' do
      subject

      expect(response).to have_http_status(200)
      expect(body_as_json.keys).to contain_exactly(*serializer_keys)
      expect(body_as_json).not_to have_key(:following)
      expect(body_as_json[:id]).to eq(tag.id.to_s)
      expect(body_as_json[:id]).to be_a(String)
      expect(body_as_json[:name]).to eq('foo')
    end

    context 'as an enabled admin' do
      let(:role) { 'admin' }
      let(:scopes) { 'admin:read' }

      it 'returns http success' do
        subject

        expect(response).to have_http_status(200)
      end
    end

    it 'returns the raw name when display_name is nil' do
      expect(tag.attributes['display_name']).to be_nil

      subject

      expect(body_as_json[:name]).to eq('foo')
    end

    it 'returns display_name as name when it is set' do
      tag.update!(display_name: 'FOO')

      subject

      expect(body_as_json[:name]).to eq('FOO')
    end

    it 'returns http not found for a missing record' do
      get '/api/v1/admin/tags/-1', headers: headers, as: :json

      expect(response).to have_http_status(404)
    end
  end

  describe 'PUT /api/v1/admin/tags/:id' do # rubocop:disable Metrics/BlockLength
    subject { put "/api/v1/admin/tags/#{tag.id}", headers: headers, params: params, as: :json }

    let!(:tag) { Fabricate(:tag, name: 'foo', reviewed_at: nil) }
    let(:params) { { display_name: 'FOO' } }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong scope', 'admin:read'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'updates display_name without changing the stored name' do
      subject

      expect(response).to have_http_status(200)
      expect(body_as_json[:name]).to eq('FOO')
      expect(tag.reload.name).to eq('foo')
      expect(tag.attributes['display_name']).to eq('FOO')
    end

    it 'rejects a display_name that changes tag identity' do
      put "/api/v1/admin/tags/#{tag.id}", headers: headers, params: { display_name: 'bar' }, as: :json

      expect(response).to have_http_status(422)
      expect(tag.reload.name).to eq('foo')
      expect(tag.attributes['display_name']).to be_nil
    end

    it 'allows a full-width equivalent display_name' do
      put "/api/v1/admin/tags/#{tag.id}", headers: headers, params: { display_name: 'ｆｏｏ' }, as: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:name]).to eq('ｆｏｏ')
      expect(tag.reload.name).to eq('foo')
    end

    it 'allows an ASCII-folding equivalent display_name' do
      folded = Fabricate(:tag, name: 'blahaj')

      put "/api/v1/admin/tags/#{folded.id}", headers: headers, params: { display_name: 'BLÅHAJ' }, as: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:name]).to eq('BLÅHAJ')
      expect(folded.reload.name).to eq('blahaj')
    end

    it 'updates trendable usable and listable including false' do
      put "/api/v1/admin/tags/#{tag.id}", headers: headers, params: { trendable: false, usable: false, listable: false }, as: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:trendable]).to eq false
      expect(body_as_json[:usable]).to eq false
      expect(body_as_json[:listable]).to eq false
      tag.reload
      expect(tag[:trendable]).to eq false
      expect(tag[:usable]).to eq false
      expect(tag[:listable]).to eq false
    end

    it 'marks the tag reviewed' do
      expect(tag.requires_review?).to be true

      put "/api/v1/admin/tags/#{tag.id}", headers: headers, params: { usable: true }, as: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:requires_review]).to eq false
      expect(tag.reload.reviewed_at).to be_present
      expect(tag.requires_review?).to be false
    end

    it 'does not write an action log' do
      expect { subject }.not_to change(Admin::ActionLog, :count)
    end

    context 'with admin:write scope' do
      let(:scopes) { 'admin:write' }

      it 'returns http success' do
        subject

        expect(response).to have_http_status(200)
      end
    end

    context 'when the staff account is disabled' do
      before { user.disable! }

      it 'returns http forbidden' do
        subject

        expect(response).to have_http_status(403)
      end
    end

    it 'returns http not found for a missing record' do
      put '/api/v1/admin/tags/-1', headers: headers, params: { display_name: 'FOO' }, as: :json

      expect(response).to have_http_status(404)
    end
  end

  describe 'PATCH /api/v1/admin/tags/:id' do
    let!(:tag) { Fabricate(:tag, name: 'foo') }

    it 'updates through PATCH' do
      patch "/api/v1/admin/tags/#{tag.id}", headers: headers, params: { trendable: true }, as: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:trendable]).to eq true
      expect(tag.reload[:trendable]).to eq true
    end
  end
end
