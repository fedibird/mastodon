require 'rails_helper'

RSpec.describe Api::V1::Admin::DomainAllowsController, type: :controller do
  render_views

  let(:role)   { 'admin' }
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

  describe 'GET #index' do
    context 'with no allowed domains' do
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

    context 'with admin:read:domain_allows scope' do
      let(:scopes) { 'admin:read:domain_allows' }

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

    context 'with allowed domains' do
      let!(:older_allow) { Fabricate(:domain_allow, domain: 'older.example', created_at: 2.days.ago) }
      let!(:newer_allow) { Fabricate(:domain_allow, domain: 'newer.example', created_at: 1.day.ago) }

      it 'returns serialized domain allows newest first' do
        get :index, format: :json

        expect(response).to have_http_status(200)
        expect(body_as_json.size).to eq(2)
        expect(body_as_json.map { |entry| entry[:id] }).to eq([newer_allow.id.to_s, older_allow.id.to_s])
        expect(body_as_json.first[:id]).to be_a(String)
        expect(body_as_json.first[:domain]).to eq(newer_allow.domain)
        expect(body_as_json.first[:created_at]).to be_present
      end

      it 'respects the limit parameter' do
        get :index, params: { limit: 1 }, format: :json

        expect(body_as_json.size).to eq(1)
        expect(body_as_json.first[:id]).to eq(newer_allow.id.to_s)
      end

      it 'sets pagination Link headers' do
        get :index, params: { limit: 1 }, format: :json

        expect(response.headers['Link'].find_link(['rel', 'next']).href).to eq api_v1_admin_domain_allows_url(limit: 1, max_id: newer_allow.id)
        expect(response.headers['Link'].find_link(['rel', 'prev']).href).to eq api_v1_admin_domain_allows_url(limit: 1, min_id: newer_allow.id)
      end
    end
  end

  describe 'GET #show' do
    let!(:domain_allow) { Fabricate(:domain_allow) }

    before do
      get :show, params: { id: domain_allow.id }, format: :json
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'
    it_behaves_like 'forbidden for wrong role', 'moderator'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'returns the serialized domain allow' do
      expect(body_as_json[:id]).to eq(domain_allow.id.to_s)
      expect(body_as_json[:domain]).to eq(domain_allow.domain)
      expect(body_as_json[:created_at]).to be_present
    end

    context 'with admin:read:domain_allows scope' do
      let(:scopes) { 'admin:read:domain_allows' }

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end
    end

    context 'when the domain allow does not exist' do
      it 'returns http not found' do
        get :show, params: { id: -1 }, format: :json
        expect(response).to have_http_status(404)
      end
    end

    context 'without a token' do
      let(:token) { nil }

      it 'returns http unauthorized' do
        expect(response).to have_http_status(401)
      end
    end
  end

  describe 'POST #create' do
    let(:params) { { domain: 'foo.bar.com' } }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { post :create, params: params, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'user' do
      before { post :create, params: params, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { post :create, params: params, format: :json }
    end

    context 'with a valid domain name' do
      it 'returns http success and persists the domain allow' do
        expect { post :create, params: params, format: :json }.to change(DomainAllow, :count).by(1)
        expect(response).to have_http_status(200)
        expect(body_as_json[:domain]).to eq('foo.bar.com')
        expect(body_as_json[:id]).to be_a(String)
        expect(DomainAllow.find_by(domain: 'foo.bar.com')).to be_present
      end

      it 'creates an Admin::ActionLog' do
        expect { post :create, params: params, format: :json }.to change(Admin::ActionLog, :count).by(1)
        expect(Admin::ActionLog.last.action).to eq(:create)
      end
    end

    context 'with admin:write scope' do
      let(:scopes) { 'admin:write' }

      it 'returns http success' do
        post :create, params: params, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with admin:write:domain_allows scope' do
      let(:scopes) { 'admin:write:domain_allows' }

      it 'returns http success' do
        post :create, params: params, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        post :create, params: params, format: :json
        expect(response).to have_http_status(403)
      end
    end

    context 'when the domain is already allowed' do
      let!(:existing) { DomainAllow.create!(domain: 'foo.bar.com') }

      it 'returns the existing record without creating a duplicate or action log' do
        expect { post :create, params: params, format: :json }.to_not change(DomainAllow, :count)
        expect(response).to have_http_status(200)
        expect(body_as_json[:id]).to eq(existing.id.to_s)
        expect { post :create, params: params, format: :json }.to_not change(Admin::ActionLog, :count)
      end
    end

    context 'when domain name is not specified' do
      it 'returns http unprocessable entity' do
        post :create, params: {}, format: :json
        expect(response).to have_http_status(422)
      end
    end

    context 'when domain name is blank' do
      it 'returns http unprocessable entity' do
        post :create, params: { domain: '' }, format: :json
        expect(response).to have_http_status(422)
      end
    end

    context 'with an invalid domain name' do
      it 'returns http unprocessable entity' do
        post :create, params: { domain: 'foo bar' }, format: :json
        expect(response).to have_http_status(422)
      end
    end

    context 'without a token' do
      let(:token) { nil }

      it 'returns http unauthorized' do
        post :create, params: params, format: :json
        expect(response).to have_http_status(401)
      end
    end
  end

  describe 'DELETE #destroy' do
    let!(:domain_allow) { Fabricate(:domain_allow) }

    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { delete :destroy, params: { id: domain_allow.id }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'user' do
      before { delete :destroy, params: { id: domain_allow.id }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'moderator' do
      before { delete :destroy, params: { id: domain_allow.id }, format: :json }
    end

    it 'returns empty JSON and removes the domain allow' do
      expect { delete :destroy, params: { id: domain_allow.id }, format: :json }.to change(DomainAllow, :count).by(-1)
      expect(response).to have_http_status(200)
      expect(body_as_json).to eq({})
      expect(DomainAllow.find_by(id: domain_allow.id)).to be_nil
    end

    it 'creates a destroy Admin::ActionLog' do
      expect { delete :destroy, params: { id: domain_allow.id }, format: :json }.to change(Admin::ActionLog, :count).by(1)
      expect(Admin::ActionLog.last.action).to eq(:destroy)
    end

    it 'uses UnallowDomainService' do
      service = instance_double(UnallowDomainService, call: true)
      allow(UnallowDomainService).to receive(:new).and_return(service)

      delete :destroy, params: { id: domain_allow.id }, format: :json

      expect(service).to have_received(:call).with(domain_allow)
    end

    context 'with admin:write:domain_allows scope' do
      let(:scopes) { 'admin:write:domain_allows' }

      it 'returns http success' do
        delete :destroy, params: { id: domain_allow.id }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        delete :destroy, params: { id: domain_allow.id }, format: :json
        expect(response).to have_http_status(403)
      end
    end

    context 'when the domain allow does not exist' do
      it 'returns http not found' do
        delete :destroy, params: { id: -1 }, format: :json
        expect(response).to have_http_status(404)
      end
    end

    context 'without a token' do
      let(:token) { nil }

      it 'returns http unauthorized' do
        delete :destroy, params: { id: domain_allow.id }, format: :json
        expect(response).to have_http_status(401)
      end
    end
  end
end
