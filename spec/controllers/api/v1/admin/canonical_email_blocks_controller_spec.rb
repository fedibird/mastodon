# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Admin::CanonicalEmailBlocksController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:role)   { 'admin' }
  let(:user)   { user_with_legacy_role_name(role, account: Fabricate(:account, username: 'alice')) }
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

  def hash_for(email)
    CanonicalEmailBlock.new.tap { |block| block.email = email }.canonical_email_hash
  end

  describe 'GET #index' do # rubocop:disable Metrics/BlockLength
    context 'with no canonical email blocks' do
      before do
        get :index, format: :json
      end

      it_behaves_like 'forbidden for wrong scope', 'write:statuses'
      it_behaves_like 'forbidden for wrong role', 'user'
      it_behaves_like 'forbidden for wrong role', 'moderator'

      it 'returns http success' do
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

    context 'with admin:read:canonical_email_blocks scope' do
      let(:scopes) { 'admin:read:canonical_email_blocks' }

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

    context 'when the admin is disabled' do
      before { user.disable! }

      it 'returns http forbidden' do
        get :index, format: :json
        expect(response).to have_http_status(403)
      end
    end

    context 'with canonical email blocks' do
      let!(:oldest) { CanonicalEmailBlock.create!(email: 'oldest@example.com') }
      let!(:middle) { CanonicalEmailBlock.create!(email: 'middle@example.com') }
      let!(:newest) { CanonicalEmailBlock.create!(email: 'newest@example.com') }

      it 'returns serialized blocks newest first with string IDs' do
        get :index, format: :json

        expect(response).to have_http_status(200)
        expect(body_as_json.map { |entry| entry[:id] }).to eq([newest.id.to_s, middle.id.to_s, oldest.id.to_s])
        expect(body_as_json.first[:id]).to be_a(String)
        expect(body_as_json.first.keys).to contain_exactly(:id, :canonical_email_hash)
        expect(body_as_json.first[:canonical_email_hash]).to eq(newest.canonical_email_hash)
      end

      it 'respects the limit parameter' do
        get :index, params: { limit: 1 }, format: :json

        expect(body_as_json.size).to eq(1)
        expect(body_as_json.first[:id]).to eq(newest.id.to_s)
      end

      it 'sets pagination Link headers' do
        get :index, params: { limit: 1 }, format: :json

        expect(response.headers['Link'].find_link(%w(rel next)).href).to eq api_v1_admin_canonical_email_blocks_url(limit: 1, max_id: newest.id)
        expect(response.headers['Link'].find_link(%w(rel prev)).href).to eq api_v1_admin_canonical_email_blocks_url(limit: 1, min_id: newest.id)
      end

      it 'paginates with max_id' do
        get :index, params: { max_id: newest.id }, format: :json
        expect(body_as_json.map { |entry| entry[:id] }).to eq([middle.id.to_s, oldest.id.to_s])
      end

      it 'paginates with since_id' do
        get :index, params: { since_id: oldest.id }, format: :json
        expect(body_as_json.map { |entry| entry[:id] }).to eq([newest.id.to_s, middle.id.to_s])
      end

      it 'paginates with min_id' do
        get :index, params: { min_id: oldest.id, limit: 2 }, format: :json
        expect(body_as_json.map { |entry| entry[:id] }).to eq([newest.id.to_s, middle.id.to_s])
      end
    end
  end

  describe 'GET #show' do
    let!(:canonical_email_block) { CanonicalEmailBlock.create!(email: 'foo@example.com') }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { get :show, params: { id: canonical_email_block.id }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { get :show, params: { id: canonical_email_block.id }, format: :json }
    end

    it 'returns the serialized canonical email block' do
      get :show, params: { id: canonical_email_block.id }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json.keys).to contain_exactly(:id, :canonical_email_hash)
      expect(body_as_json[:id]).to eq(canonical_email_block.id.to_s)
      expect(body_as_json[:id]).to be_a(String)
      expect(body_as_json[:canonical_email_hash]).to eq(canonical_email_block.canonical_email_hash)
    end

    context 'with admin:read:canonical_email_blocks scope' do
      let(:scopes) { 'admin:read:canonical_email_blocks' }

      it 'returns http success' do
        get :show, params: { id: canonical_email_block.id }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    it 'returns http not found for a missing record' do
      get :show, params: { id: -1 }, format: :json
      expect(response).to have_http_status(404)
    end
  end

  describe 'POST #test' do # rubocop:disable Metrics/BlockLength
    let!(:canonical_email_block) { CanonicalEmailBlock.create!(email: 'foo@example.com') }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { post :test, params: { email: 'foo@example.com' }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { post :test, params: { email: 'foo@example.com' }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'user' do
      before { post :test, params: { email: 'foo@example.com' }, format: :json }
    end

    it 'returns matching blocks for an exact email' do
      post :test, params: { email: 'foo@example.com' }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json.map { |entry| entry[:id] }).to eq([canonical_email_block.id.to_s])
    end

    it 'matches a dotted variant' do
      post :test, params: { email: 'f.oo@example.com' }, format: :json
      expect(body_as_json.map { |entry| entry[:id] }).to eq([canonical_email_block.id.to_s])
    end

    it 'matches a plus-extension variant' do
      post :test, params: { email: 'foo+something@example.com' }, format: :json
      expect(body_as_json.map { |entry| entry[:id] }).to eq([canonical_email_block.id.to_s])
    end

    it 'matches a case variant' do
      post :test, params: { email: 'Foo@EXAMPLE.com' }, format: :json
      expect(body_as_json.map { |entry| entry[:id] }).to eq([canonical_email_block.id.to_s])
    end

    it 'returns an empty array when nothing matches' do
      post :test, params: { email: 'other@example.com' }, format: :json
      expect(response).to have_http_status(200)
      expect(body_as_json).to eq([])
    end

    it 'returns 400 when email is missing' do
      post :test, params: {}, format: :json
      expect(response).to have_http_status(400)
    end

    context 'with admin:read:canonical_email_blocks scope' do
      let(:scopes) { 'admin:read:canonical_email_blocks' }

      it 'returns http success' do
        post :test, params: { email: 'foo@example.com' }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with a write-only scope' do
      let(:scopes) { 'admin:write' }

      it 'returns http forbidden' do
        post :test, params: { email: 'foo@example.com' }, format: :json
        expect(response).to have_http_status(403)
      end
    end
  end

  describe 'POST #create' do # rubocop:disable Metrics/BlockLength
    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { post :create, params: { email: 'foo@example.com' }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'user' do
      before { post :create, params: { email: 'foo@example.com' }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { post :create, params: { email: 'foo@example.com' }, format: :json }
    end

    it 'creates a manual block from email and logs the action' do
      expect { post :create, params: { email: 'foo@example.com' }, format: :json }
        .to change(CanonicalEmailBlock, :count).by(1).and change(Admin::ActionLog, :count).by(1)

      expect(response).to have_http_status(200)
      expect(body_as_json.keys).to contain_exactly(:id, :canonical_email_hash)
      expect(body_as_json[:id]).to be_a(String)
      expect(body_as_json[:canonical_email_hash]).to eq(hash_for('foo@example.com'))
      expect(CanonicalEmailBlock.find(body_as_json[:id]).reference_account_id).to be_nil
      expect(Admin::ActionLog.last.action).to eq(:create)
    end

    it 'creates a block from a canonical_email_hash' do
      digest = hash_for('hash-only@example.com')
      post :create, params: { canonical_email_hash: digest }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:canonical_email_hash]).to eq(digest)
      expect(CanonicalEmailBlock.find(body_as_json[:id]).reference_account_id).to be_nil
    end

    it 'lets email win when both email and canonical_email_hash are supplied' do
      other_hash = hash_for('other@example.com')
      post :create, params: { canonical_email_hash: other_hash, email: 'foo@example.com' }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:canonical_email_hash]).to eq(hash_for('foo@example.com'))
      expect(body_as_json[:canonical_email_hash]).not_to eq(other_hash)
    end

    it 'returns 422 when both email and canonical_email_hash are missing' do
      post :create, params: {}, format: :json
      expect(response).to have_http_status(422)
    end

    it 'returns 422 for a duplicate canonical email' do
      CanonicalEmailBlock.create!(email: 'foo@example.com')
      post :create, params: { email: 'f.oo+test@example.com' }, format: :json
      expect(response).to have_http_status(422)
    end

    context 'with admin:write scope' do
      let(:scopes) { 'admin:write' }

      it 'returns http success' do
        post :create, params: { email: 'write@example.com' }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with admin:write:canonical_email_blocks scope' do
      let(:scopes) { 'admin:write:canonical_email_blocks' }

      it 'returns http success' do
        post :create, params: { email: 'granular@example.com' }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        post :create, params: { email: 'readonly@example.com' }, format: :json
        expect(response).to have_http_status(403)
      end
    end

    context 'without a token' do
      let(:token) { nil }

      it 'returns http unauthorized' do
        post :create, params: { email: 'notoken@example.com' }, format: :json
        expect(response).to have_http_status(401)
      end
    end
  end

  describe 'DELETE #destroy' do
    let!(:canonical_email_block) { CanonicalEmailBlock.create!(email: 'foo@example.com') }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { delete :destroy, params: { id: canonical_email_block.id }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { delete :destroy, params: { id: canonical_email_block.id }, format: :json }
    end

    it 'returns empty JSON, removes the block, and logs destroy' do
      expect { delete :destroy, params: { id: canonical_email_block.id }, format: :json }
        .to change(CanonicalEmailBlock, :count).by(-1).and change(Admin::ActionLog, :count).by(1)
      expect(response).to have_http_status(200)
      expect(body_as_json).to eq({})
      expect(CanonicalEmailBlock.find_by(id: canonical_email_block.id)).to be_nil
      expect(Admin::ActionLog.last.action).to eq(:destroy)
    end

    it 'returns http not found for a missing record' do
      delete :destroy, params: { id: -1 }, format: :json
      expect(response).to have_http_status(404)
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        delete :destroy, params: { id: canonical_email_block.id }, format: :json
        expect(response).to have_http_status(403)
      end
    end
  end

  describe 'disabled admin' do
    before { user.disable! }

    it 'forbids index with a valid admin token' do
      get :index, format: :json
      expect(response).to have_http_status(403)
    end

    it 'forbids test with a valid admin token' do
      post :test, params: { email: 'foo@example.com' }, format: :json
      expect(response).to have_http_status(403)
    end

    it 'forbids create with a valid admin token' do
      post :create, params: { email: 'disabled@example.com' }, format: :json
      expect(response).to have_http_status(403)
    end

    it 'forbids destroy with a valid admin token' do
      block = CanonicalEmailBlock.create!(email: 'disabled-delete@example.com')
      delete :destroy, params: { id: block.id }, format: :json
      expect(response).to have_http_status(403)
    end
  end
end
