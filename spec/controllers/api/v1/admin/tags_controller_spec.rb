# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Admin::TagsController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  def serializer_keys
    %i(id name url history trendable usable requires_review listable)
  end

  let(:role)   { 'moderator' }
  let(:user)   { Fabricate(:user, role: role, account: Fabricate(:account, username: 'alice')) }
  let(:scopes) { 'admin:read admin:write' }
  let(:token)  { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  shared_examples 'forbidden for wrong scope' do |wrong_scope|
    let(:scopes) { wrong_scope }

    it 'returns http forbidden' do
      expect(response).to have_http_status(403)
    end
  end

  shared_examples 'forbidden for wrong role' do |wrong_role|
    let(:role) { wrong_role }

    it 'returns http forbidden' do
      expect(response).to have_http_status(403)
    end
  end

  describe 'GET #index' do # rubocop:disable Metrics/BlockLength
    context 'with no tags' do
      before do
        get :index, format: :json
      end

      it_behaves_like 'forbidden for wrong scope', 'write:statuses'
      it_behaves_like 'forbidden for wrong role', 'user'

      it 'returns http success for a moderator' do
        expect(response).to have_http_status(200)
      end

      it 'returns an empty array' do
        expect(body_as_json).to eq([])
      end
    end

    context 'with admin:read scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http success' do
        get :index, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'as an enabled admin' do
      let(:role) { 'admin' }

      it 'returns http success' do
        get :index, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'without a token' do
      let(:token) { nil }

      it 'returns http unauthorized' do
        get :index, format: :json
        expect(response).to have_http_status(401)
      end
    end

    context 'when the staff account is disabled' do
      before { user.disable! }

      it 'returns http forbidden for a disabled moderator' do
        get :index, format: :json
        expect(response).to have_http_status(403)
      end

      context 'as a disabled admin' do
        let(:role) { 'admin' }

        it 'returns http forbidden' do
          get :index, format: :json
          expect(response).to have_http_status(403)
        end
      end
    end

    context 'with tags' do
      let!(:older) { Fabricate(:tag, name: 'alpha') }
      let!(:newer) { Fabricate(:tag, name: 'beta') }

      it 'returns serialized tags newest first with string ids' do
        get :index, format: :json

        expect(response).to have_http_status(200)
        expect(body_as_json.map { |entry| entry[:id] }).to eq([newer.id.to_s, older.id.to_s])
        expect(body_as_json.first[:id]).to be_a(String)
        expect(body_as_json.first.keys).to contain_exactly(*serializer_keys)
      end

      it 'respects the limit parameter' do
        get :index, params: { limit: 1 }, format: :json

        expect(body_as_json.size).to eq(1)
        expect(body_as_json.first[:id]).to eq(newer.id.to_s)
      end

      it 'sets pagination Link headers' do
        get :index, params: { limit: 1 }, format: :json

        expect(response.headers['Link'].find_link(%w(rel next)).href).to eq api_v1_admin_tags_url(limit: 1, max_id: newer.id)
        expect(response.headers['Link'].find_link(%w(rel prev)).href).to eq api_v1_admin_tags_url(limit: 1, min_id: newer.id)
      end

      it 'paginates with max_id' do
        get :index, params: { max_id: newer.id }, format: :json
        expect(body_as_json.map { |entry| entry[:id] }).to eq([older.id.to_s])
      end

      it 'paginates with since_id' do
        get :index, params: { since_id: older.id }, format: :json
        expect(body_as_json.map { |entry| entry[:id] }).to eq([newer.id.to_s])
      end

      it 'paginates with min_id' do
        get :index, params: { min_id: older.id, limit: 2 }, format: :json
        expect(body_as_json.map { |entry| entry[:id] }).to eq([newer.id.to_s])
      end
    end
  end

  describe 'GET #show' do
    let!(:tag) { Fabricate(:tag, name: 'foo') }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { get :show, params: { id: tag.id }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'user' do
      before { get :show, params: { id: tag.id }, format: :json }
    end

    it 'returns the serialized tag for a moderator' do
      get :show, params: { id: tag.id }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json.keys).to contain_exactly(*serializer_keys)
      expect(body_as_json[:id]).to eq(tag.id.to_s)
      expect(body_as_json[:id]).to be_a(String)
      expect(body_as_json[:name]).to eq('foo')
    end

    context 'as an enabled admin' do
      let(:role) { 'admin' }

      it 'returns http success' do
        get :show, params: { id: tag.id }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    it 'returns http not found for a missing record' do
      get :show, params: { id: -1 }, format: :json
      expect(response).to have_http_status(404)
    end
  end

  describe 'PUT #update' do # rubocop:disable Metrics/BlockLength
    let!(:tag) { Fabricate(:tag, name: 'foo', reviewed_at: nil) }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { put :update, params: { id: tag.id, display_name: 'FOO' }, format: :json }
    end

    it_behaves_like 'forbidden for wrong scope', 'admin:read' do
      before { put :update, params: { id: tag.id, display_name: 'FOO' }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'user' do
      before { put :update, params: { id: tag.id, display_name: 'FOO' }, format: :json }
    end

    it 'updates display_name without changing the stored name' do
      put :update, params: { id: tag.id, display_name: 'FOO' }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:name]).to eq('FOO')
      expect(tag.reload.name).to eq('foo')
      expect(tag.attributes['display_name']).to eq('FOO')
    end

    it 'rejects a display_name that changes tag identity' do
      put :update, params: { id: tag.id, display_name: 'bar' }, format: :json

      expect(response).to have_http_status(422)
      expect(tag.reload.name).to eq('foo')
      expect(tag.attributes['display_name']).to be_nil
    end

    it 'allows a full-width equivalent display_name' do
      put :update, params: { id: tag.id, display_name: 'ｆｏｏ' }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:name]).to eq('ｆｏｏ')
      expect(tag.reload.name).to eq('foo')
    end

    it 'allows an ASCII-folding equivalent display_name' do
      tag.update_columns(name: 'blahaj') # rubocop:disable Rails/SkipsModelValidations

      put :update, params: { id: tag.id, display_name: 'BLÅHAJ' }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:name]).to eq('BLÅHAJ')
      expect(tag.reload.name).to eq('blahaj')
    end

    it 'updates trendable usable and listable including false' do
      put :update, params: { id: tag.id, trendable: false, usable: false, listable: false }, format: :json

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

      put :update, params: { id: tag.id, usable: true }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:requires_review]).to eq false
      expect(tag.reload.reviewed_at).to be_present
      expect(tag.requires_review?).to be false
    end

    it 'does not write an action log' do
      expect { put :update, params: { id: tag.id, display_name: 'FOO' }, format: :json }
        .not_to change(Admin::ActionLog, :count)
    end
  end

  describe 'PATCH #update' do
    let!(:tag) { Fabricate(:tag, name: 'foo') }

    it 'updates through PATCH' do
      patch :update, params: { id: tag.id, trendable: true }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:trendable]).to eq true
      expect(tag.reload[:trendable]).to eq true
    end
  end
end
