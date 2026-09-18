require 'rails_helper'

RSpec.describe Api::V1::Admin::ReportsController, type: :controller do
  render_views

  let(:role)   { 'moderator' }
  let(:user)   { Fabricate(:user, role: role, account: Fabricate(:account, username: 'alice')) }
  let(:scopes) { 'admin:read admin:write' }
  let(:token)  { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:report) { Fabricate(:report) }

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
    before do
      get :index
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end
  end

  describe 'GET #show' do
    before do
      get :show, params: { id: report.id }
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end
  end

  describe 'POST #resolve' do
    before do
      post :resolve, params: { id: report.id }
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end
  end

  describe 'POST #reopen' do
    before do
      post :reopen, params: { id: report.id }
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end
  end

  describe 'POST #assign_to_self' do
    before do
      post :assign_to_self, params: { id: report.id }
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end
  end

  describe 'POST #unassign' do
    before do
      post :unassign, params: { id: report.id }
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end
  end

  describe 'disabled staff' do
    before { user.disable! }

    it 'forbids a disabled moderator from reading reports' do
      get :index, format: :json
      expect(response).to have_http_status(403)
    end

    it 'forbids a disabled moderator from writing reports' do
      post :resolve, params: { id: report.id }, format: :json
      expect(response).to have_http_status(403)
    end

    context 'as a disabled admin' do
      let(:role) { 'admin' }

      it 'forbids reading reports with a valid admin token' do
        get :show, params: { id: report.id }, format: :json
        expect(response).to have_http_status(403)
      end
    end
  end
end
