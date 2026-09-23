# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Admin::IpBlocksController, type: :controller do # rubocop:disable Metrics/BlockLength
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

  describe 'GET #index' do # rubocop:disable Metrics/BlockLength
    context 'with no IP blocks' do
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

    context 'with admin:read:ip_blocks scope' do
      let(:scopes) { 'admin:read:ip_blocks' }

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

    context 'with IP blocks' do
      let!(:oldest) { Fabricate(:ip_block, ip: '192.0.2.1', severity: :no_access, comment: 'oldest') }
      let!(:middle) { Fabricate(:ip_block, ip: '192.0.2.2', severity: :sign_up_block, comment: 'middle') }
      let!(:newest) { Fabricate(:ip_block, ip: '192.0.2.0/24', severity: :sign_up_requires_approval, comment: 'newest') }
      let!(:ipv6)   { Fabricate(:ip_block, ip: '2001:db8::/32', severity: :no_access, comment: 'ipv6') }

      it 'returns serialized IP blocks newest first with string IDs' do
        get :index, format: :json

        expect(response).to have_http_status(200)
        expect(body_as_json.map { |entry| entry[:id] }).to eq([ipv6.id.to_s, newest.id.to_s, middle.id.to_s, oldest.id.to_s])
        expect(body_as_json.first[:id]).to be_a(String)
        expect(body_as_json.first).to include(
          ip: '2001:db8::/32',
          severity: 'no_access',
          comment: 'ipv6'
        )
        expect(body_as_json.first).to have_key(:created_at)
        expect(body_as_json.first).to have_key(:expires_at)
      end

      it 'serializes IPv4 hosts with a /32 prefix' do
        get :index, format: :json
        entry = body_as_json.find { |item| item[:id] == oldest.id.to_s }
        expect(entry[:ip]).to eq('192.0.2.1/32')
      end

      it 'serializes IPv4 CIDR blocks with their prefix' do
        get :index, format: :json
        entry = body_as_json.find { |item| item[:id] == newest.id.to_s }
        expect(entry[:ip]).to eq('192.0.2.0/24')
      end

      it 'respects the limit parameter' do
        get :index, params: { limit: 1 }, format: :json

        expect(body_as_json.size).to eq(1)
        expect(body_as_json.first[:id]).to eq(ipv6.id.to_s)
      end

      it 'sets pagination Link headers' do
        get :index, params: { limit: 1 }, format: :json

        expect(response.headers['Link'].find_link(%w(rel next)).href).to eq api_v1_admin_ip_blocks_url(limit: 1, max_id: ipv6.id)
        expect(response.headers['Link'].find_link(%w(rel prev)).href).to eq api_v1_admin_ip_blocks_url(limit: 1, min_id: ipv6.id)
      end

      it 'paginates with max_id' do
        get :index, params: { max_id: ipv6.id }, format: :json
        expect(body_as_json.map { |entry| entry[:id] }).to eq([newest.id.to_s, middle.id.to_s, oldest.id.to_s])
      end

      it 'paginates with since_id' do
        get :index, params: { since_id: oldest.id }, format: :json
        expect(body_as_json.map { |entry| entry[:id] }).to eq([ipv6.id.to_s, newest.id.to_s, middle.id.to_s])
      end

      it 'paginates with min_id' do
        get :index, params: { min_id: oldest.id, limit: 2 }, format: :json
        expect(body_as_json.map { |entry| entry[:id] }).to eq([newest.id.to_s, middle.id.to_s])
      end
    end
  end

  describe 'GET #show' do
    let!(:ip_block) { Fabricate(:ip_block, ip: '192.0.2.1', severity: :no_access, comment: 'Spam') }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { get :show, params: { id: ip_block.id }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { get :show, params: { id: ip_block.id }, format: :json }
    end

    it 'returns the serialized IP block' do
      get :show, params: { id: ip_block.id }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        id: ip_block.id.to_s,
        ip: '192.0.2.1/32',
        severity: 'no_access',
        comment: 'Spam'
      )
      expect(body_as_json[:id]).to be_a(String)
      expect(body_as_json[:created_at]).to be_present
      expect(body_as_json).to have_key(:expires_at)
    end

    context 'with admin:read:ip_blocks scope' do
      let(:scopes) { 'admin:read:ip_blocks' }

      it 'returns http success' do
        get :show, params: { id: ip_block.id }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    it 'returns http not found for a missing record' do
      get :show, params: { id: -1 }, format: :json
      expect(response).to have_http_status(404)
    end
  end

  describe 'POST #create' do # rubocop:disable Metrics/BlockLength
    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { post :create, params: { ip: '192.0.2.1', severity: 'no_access' }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'user' do
      before { post :create, params: { ip: '192.0.2.1', severity: 'no_access' }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { post :create, params: { ip: '192.0.2.1', severity: 'no_access' }, format: :json }
    end

    it 'creates a no_access block and logs the action' do
      expect { post :create, params: { ip: '192.0.2.1', severity: 'no_access', comment: 'Spam' }, format: :json }
        .to change(IpBlock, :count).by(1).and change(Admin::ActionLog, :count).by(1)
      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to be_a(String)
      expect(body_as_json[:ip]).to eq('192.0.2.1/32')
      expect(body_as_json[:severity]).to eq('no_access')
      expect(body_as_json[:comment]).to eq('Spam')
      expect(body_as_json[:expires_at]).to be_nil
      expect(Admin::ActionLog.last.action).to eq(:create)
    end

    it 'creates a sign_up_requires_approval block' do
      post :create, params: { ip: '192.0.2.2', severity: 'sign_up_requires_approval' }, format: :json
      expect(response).to have_http_status(200)
      expect(body_as_json[:severity]).to eq('sign_up_requires_approval')
    end

    it 'creates a sign_up_block' do
      post :create, params: { ip: '192.0.2.3', severity: 'sign_up_block' }, format: :json
      expect(response).to have_http_status(200)
      expect(body_as_json[:severity]).to eq('sign_up_block')
    end

    it 'persists expires_in as a future expires_at' do
      freeze_time do
        post :create, params: { ip: '192.0.2.4', severity: 'no_access', expires_in: 86_400 }, format: :json
        expect(response).to have_http_status(200)
        expect(Time.zone.parse(body_as_json[:expires_at])).to be_within(1.second).of(1.day.from_now)
      end
    end

    context 'with admin:write scope' do
      let(:scopes) { 'admin:write' }

      it 'returns http success' do
        post :create, params: { ip: '192.0.2.5', severity: 'no_access' }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with admin:write:ip_blocks scope' do
      let(:scopes) { 'admin:write:ip_blocks' }

      it 'returns http success' do
        post :create, params: { ip: '192.0.2.6', severity: 'no_access' }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        post :create, params: { ip: '192.0.2.7', severity: 'no_access' }, format: :json
        expect(response).to have_http_status(403)
      end
    end

    it 'returns 422 when IP is missing' do
      post :create, params: { severity: 'no_access' }, format: :json
      expect(response).to have_http_status(422)
    end

    it 'returns 422 when IP is blank' do
      post :create, params: { ip: '', severity: 'no_access' }, format: :json
      expect(response).to have_http_status(422)
    end

    it 'returns 422 when IP is invalid' do
      post :create, params: { ip: 'not-an-ip', severity: 'no_access' }, format: :json
      expect(response).to have_http_status(422)
    end

    it 'returns 422 when severity is missing' do
      post :create, params: { ip: '192.0.2.8' }, format: :json
      expect(response).to have_http_status(422)
    end

    it 'returns 422 for a duplicate exact IP' do
      Fabricate(:ip_block, ip: '192.0.2.9', severity: :no_access)
      post :create, params: { ip: '192.0.2.9', severity: 'sign_up_block' }, format: :json
      expect(response).to have_http_status(422)
    end

    it 'returns 422 for a duplicate CIDR' do
      Fabricate(:ip_block, ip: '198.51.100.0/24', severity: :no_access)
      post :create, params: { ip: '198.51.100.0/24', severity: 'sign_up_block' }, format: :json
      expect(response).to have_http_status(422)
    end
  end

  describe 'PUT/PATCH #update' do
    let!(:ip_block) { Fabricate(:ip_block, ip: '192.0.2.10', severity: :no_access, comment: 'old') }

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { put :update, params: { id: ip_block.id, severity: 'sign_up_block' }, format: :json }
    end

    it 'updates via PUT and logs the action' do
      expect { put :update, params: { id: ip_block.id, severity: 'sign_up_block', comment: 'updated' }, format: :json }
        .to change(Admin::ActionLog, :count).by(1)
      expect(response).to have_http_status(200)
      expect(body_as_json[:severity]).to eq('sign_up_block')
      expect(body_as_json[:comment]).to eq('updated')
      expect(ip_block.reload.severity).to eq('sign_up_block')
      expect(Admin::ActionLog.last.action).to eq(:update)
    end

    it 'updates via PATCH' do
      patch :update, params: { id: ip_block.id, comment: 'patched' }, format: :json
      expect(response).to have_http_status(200)
      expect(ip_block.reload.comment).to eq('patched')
    end

    it 'allows updating the IP address' do
      put :update, params: { id: ip_block.id, ip: '198.51.100.1' }, format: :json
      expect(response).to have_http_status(200)
      expect(body_as_json[:ip]).to eq('198.51.100.1/32')
      expect(ip_block.reload.ip.to_s).to eq('198.51.100.1')
    end

    it 'updates expiry' do
      freeze_time do
        put :update, params: { id: ip_block.id, expires_in: 86_400 }, format: :json
        expect(response).to have_http_status(200)
        expect(Time.zone.parse(body_as_json[:expires_at])).to be_within(1.second).of(1.day.from_now)
      end
    end

    it 'clears expiry when expires_in is blank' do
      ip_block.update!(expires_in: 1.day)
      put :update, params: { id: ip_block.id, expires_in: '' }, format: :json
      expect(response).to have_http_status(200)
      expect(body_as_json[:expires_at]).to be_nil
      expect(ip_block.reload.expires_at).to be_nil
    end

    it 'returns http not found for a missing record' do
      put :update, params: { id: -1, severity: 'sign_up_block' }, format: :json
      expect(response).to have_http_status(404)
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        put :update, params: { id: ip_block.id, severity: 'sign_up_block' }, format: :json
        expect(response).to have_http_status(403)
      end
    end

    it 'resets the no_access cache when severity changes' do
      expect(IpBlock.blocked?('192.0.2.10')).to be true
      put :update, params: { id: ip_block.id, severity: 'sign_up_block' }, format: :json
      expect(IpBlock.blocked?('192.0.2.10')).to be false
    end
  end

  describe 'DELETE #destroy' do
    let!(:ip_block) { Fabricate(:ip_block, ip: '192.0.2.11', severity: :no_access) }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { delete :destroy, params: { id: ip_block.id }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { delete :destroy, params: { id: ip_block.id }, format: :json }
    end

    it 'returns empty JSON, removes the IP block, and logs destroy' do
      expect { delete :destroy, params: { id: ip_block.id }, format: :json }
        .to change(IpBlock, :count).by(-1).and change(Admin::ActionLog, :count).by(1)
      expect(response).to have_http_status(200)
      expect(body_as_json).to eq({})
      expect(IpBlock.find_by(id: ip_block.id)).to be_nil
      expect(Admin::ActionLog.last.action).to eq(:destroy)
    end

    it 'returns http not found for a missing record' do
      delete :destroy, params: { id: -1 }, format: :json
      expect(response).to have_http_status(404)
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        delete :destroy, params: { id: ip_block.id }, format: :json
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

    it 'forbids create with a valid admin token' do
      post :create, params: { ip: '192.0.2.12', severity: 'no_access' }, format: :json
      expect(response).to have_http_status(403)
    end
  end
end
