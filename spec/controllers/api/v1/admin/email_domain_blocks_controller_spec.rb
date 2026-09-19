# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Admin::EmailDomainBlocksController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:role)   { 'admin' }
  let(:user)   { Fabricate(:user, role: role, account: Fabricate(:account, username: 'alice')) }
  let(:scopes) { 'admin:read admin:write' }
  let(:token)  { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:now)    { Time.utc(2026, 9, 19, 12, 0, 0) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  around do |example|
    travel_to(now) { example.run }
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
    context 'with no email domain blocks' do
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

    context 'with admin:read:email_domain_blocks scope' do
      let(:scopes) { 'admin:read:email_domain_blocks' }

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

    context 'with email domain blocks' do
      let!(:parent)   { Fabricate(:email_domain_block, domain: 'example.com') }
      let!(:child_mx) { Fabricate(:email_domain_block, domain: 'mail.example.com', parent: parent) }
      let!(:child_ip) { Fabricate(:email_domain_block, domain: '1.2.3.4', parent: parent) }

      it 'returns parent and child rows newest first with string IDs' do
        get :index, format: :json

        expect(response).to have_http_status(200)
        expect(body_as_json.map { |entry| entry[:id] }).to eq([child_ip.id.to_s, child_mx.id.to_s, parent.id.to_s])
        expect(body_as_json.first[:id]).to be_a(String)
        expect(body_as_json.map { |entry| entry[:domain] }).to include('example.com', 'mail.example.com', '1.2.3.4')
        expect(body_as_json.first.keys).to contain_exactly(:id, :domain, :created_at, :history)
      end

      it 'respects the limit parameter' do
        get :index, params: { limit: 1 }, format: :json

        expect(body_as_json.size).to eq(1)
        expect(body_as_json.first[:id]).to eq(child_ip.id.to_s)
      end

      it 'sets pagination Link headers' do
        get :index, params: { limit: 1 }, format: :json

        expect(response.headers['Link'].find_link(%w(rel next)).href).to eq api_v1_admin_email_domain_blocks_url(limit: 1, max_id: child_ip.id)
        expect(response.headers['Link'].find_link(%w(rel prev)).href).to eq api_v1_admin_email_domain_blocks_url(limit: 1, min_id: child_ip.id)
      end

      it 'paginates with max_id' do
        get :index, params: { max_id: child_ip.id }, format: :json
        expect(body_as_json.map { |entry| entry[:id] }).to eq([child_mx.id.to_s, parent.id.to_s])
      end

      it 'paginates with since_id' do
        get :index, params: { since_id: parent.id }, format: :json
        expect(body_as_json.map { |entry| entry[:id] }).to eq([child_ip.id.to_s, child_mx.id.to_s])
      end

      it 'paginates with min_id' do
        get :index, params: { min_id: parent.id, limit: 2 }, format: :json
        expect(body_as_json.map { |entry| entry[:id] }).to eq([child_ip.id.to_s, child_mx.id.to_s])
      end
    end
  end

  describe 'GET #show' do
    let!(:email_domain_block) { Fabricate(:email_domain_block, domain: 'example.com') }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { get :show, params: { id: email_domain_block.id }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { get :show, params: { id: email_domain_block.id }, format: :json }
    end

    it 'returns the serialized email domain block' do
      get :show, params: { id: email_domain_block.id }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json.keys).to contain_exactly(:id, :domain, :created_at, :history)
      expect(body_as_json[:id]).to eq(email_domain_block.id.to_s)
      expect(body_as_json[:id]).to be_a(String)
      expect(body_as_json[:domain]).to eq('example.com')
      expect(body_as_json[:created_at]).to be_present
      expect(body_as_json[:history].size).to eq(7)
      expect(body_as_json[:history].first[:day]).to be_a(String)
      expect(body_as_json[:history].first[:accounts]).to be_a(String)
      expect(body_as_json[:history].first[:uses]).to be_a(String)
    end

    it 'returns recorded signup attempt history' do
      email_domain_block.history.add('192.0.2.1')
      email_domain_block.history.add('192.0.2.1')
      email_domain_block.history.add('192.0.2.2')

      get :show, params: { id: email_domain_block.id }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:history].first[:uses]).to eq('3')
      expect(body_as_json[:history].first[:accounts]).to eq('2')
    end

    it 'returns a child block' do
      child = Fabricate(:email_domain_block, domain: 'mail.example.com', parent: email_domain_block)

      get :show, params: { id: child.id }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq(child.id.to_s)
      expect(body_as_json[:domain]).to eq('mail.example.com')
    end

    context 'with admin:read:email_domain_blocks scope' do
      let(:scopes) { 'admin:read:email_domain_blocks' }

      it 'returns http success' do
        get :show, params: { id: email_domain_block.id }, format: :json
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
      before { post :create, params: { domain: 'example.com' }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'user' do
      before { post :create, params: { domain: 'example.com' }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { post :create, params: { domain: 'example.com' }, format: :json }
    end

    it 'creates an email domain block and logs the action' do
      expect { post :create, params: { domain: 'example.com' }, format: :json }
        .to change(EmailDomainBlock, :count).by(1).and change(Admin::ActionLog, :count).by(1)
      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to be_a(String)
      expect(body_as_json[:domain]).to eq('example.com')
      expect(body_as_json.keys).to contain_exactly(:id, :domain, :created_at, :history)
      expect(Admin::ActionLog.last.action).to eq(:create)
    end

    it 'normalizes the domain' do
      post :create, params: { domain: 'EXAMPLE.COM' }, format: :json
      expect(response).to have_http_status(200)
      expect(body_as_json[:domain]).to eq('example.com')
    end

    it 'ignores with_dns_records and does not create child records' do
      expect { post :create, params: { domain: 'dns.example', with_dns_records: true, parent_id: 1 }, format: :json }
        .to change(EmailDomainBlock, :count).by(1)
      expect(response).to have_http_status(200)
      block = EmailDomainBlock.find(body_as_json[:id])
      expect(block.children).to be_empty
      expect(block.parent_id).to be_nil
    end

    context 'with admin:write scope' do
      let(:scopes) { 'admin:write' }

      it 'returns http success' do
        post :create, params: { domain: 'write.example' }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with admin:write:email_domain_blocks scope' do
      let(:scopes) { 'admin:write:email_domain_blocks' }

      it 'returns http success' do
        post :create, params: { domain: 'granular.example' }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        post :create, params: { domain: 'readonly.example' }, format: :json
        expect(response).to have_http_status(403)
      end
    end

    it 'returns 422 when domain is missing' do
      post :create, params: {}, format: :json
      expect(response).to have_http_status(422)
    end

    it 'returns 422 when domain is blank' do
      post :create, params: { domain: '' }, format: :json
      expect(response).to have_http_status(422)
    end

    it 'returns 422 when domain is invalid' do
      post :create, params: { domain: 'foo bar' }, format: :json
      expect(response).to have_http_status(422)
    end

    it 'returns 422 for a duplicate domain' do
      Fabricate(:email_domain_block, domain: 'dup.example')
      post :create, params: { domain: 'dup.example' }, format: :json
      expect(response).to have_http_status(422)
    end
  end

  describe 'DELETE #destroy' do
    let!(:email_domain_block) { Fabricate(:email_domain_block, domain: 'example.com') }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { delete :destroy, params: { id: email_domain_block.id }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { delete :destroy, params: { id: email_domain_block.id }, format: :json }
    end

    it 'returns empty JSON, removes the block, and logs destroy' do
      expect { delete :destroy, params: { id: email_domain_block.id }, format: :json }
        .to change(EmailDomainBlock, :count).by(-1).and change(Admin::ActionLog, :count).by(1)
      expect(response).to have_http_status(200)
      expect(body_as_json).to eq({})
      expect(EmailDomainBlock.find_by(id: email_domain_block.id)).to be_nil
      expect(Admin::ActionLog.last.action).to eq(:destroy)
    end

    it 'deletes a child block without removing the parent' do
      child = Fabricate(:email_domain_block, domain: 'mail.example.com', parent: email_domain_block)

      expect { delete :destroy, params: { id: child.id }, format: :json }
        .to change(EmailDomainBlock, :count).by(-1)
      expect(response).to have_http_status(200)
      expect(EmailDomainBlock.find_by(id: child.id)).to be_nil
      expect(EmailDomainBlock.find_by(id: email_domain_block.id)).to eq(email_domain_block)
    end

    it 'cascades children when the parent is deleted' do
      child_mx = Fabricate(:email_domain_block, domain: 'mail.example.com', parent: email_domain_block)
      child_ip = Fabricate(:email_domain_block, domain: '1.2.3.4', parent: email_domain_block)

      expect { delete :destroy, params: { id: email_domain_block.id }, format: :json }
        .to change(EmailDomainBlock, :count).by(-3)
      expect(response).to have_http_status(200)
      expect(EmailDomainBlock.find_by(id: email_domain_block.id)).to be_nil
      expect(EmailDomainBlock.find_by(id: child_mx.id)).to be_nil
      expect(EmailDomainBlock.find_by(id: child_ip.id)).to be_nil
    end

    it 'returns http not found for a missing record' do
      delete :destroy, params: { id: -1 }, format: :json
      expect(response).to have_http_status(404)
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        delete :destroy, params: { id: email_domain_block.id }, format: :json
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
      post :create, params: { domain: 'disabled.example' }, format: :json
      expect(response).to have_http_status(403)
    end

    it 'forbids destroy with a valid admin token' do
      block = Fabricate(:email_domain_block, domain: 'disabled-delete.example')
      delete :destroy, params: { id: block.id }, format: :json
      expect(response).to have_http_status(403)
    end
  end
end
