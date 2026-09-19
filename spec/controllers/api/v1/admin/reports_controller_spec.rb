# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Admin::ReportsController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  def serializer_keys
    %i(
      id action_taken action_taken_at category comment forwarded
      created_at updated_at account target_account assigned_account
      action_taken_by_account statuses rules
    )
  end

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
      get :index, format: :json
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    context 'with admin:read scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http success' do
        get :index, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with admin:read:reports scope' do
      let(:scopes) { 'admin:read:reports' }

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

    context 'as an enabled admin' do
      let(:role) { 'admin' }

      it 'returns http success' do
        get :index, format: :json
        expect(response).to have_http_status(200)
      end
    end

    it 'returns the 4.2 admin report serializer shape' do
      report = Fabricate(:report, category: :other, forwarded: true)

      get :index, format: :json

      entry = body_as_json.find { |item| item[:id] == report.id.to_s }
      expect(entry.keys).to include(*serializer_keys)
      expect(entry[:id]).to be_a(String)
      expect(entry[:action_taken]).to eq false
      expect(entry[:action_taken_at]).to be_nil
      expect(entry[:category]).to eq 'other'
      expect(entry[:forwarded]).to eq true
      expect(entry[:rules]).to eq []
    end
  end

  describe 'GET #show' do
    before do
      get :show, params: { id: report.id }, format: :json
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'returns action_taken as a boolean and action_taken_at as null' do
      get :show, params: { id: report.id }, format: :json

      expect(body_as_json[:action_taken]).to eq false
      expect(body_as_json[:action_taken_at]).to be_nil
      expect(body_as_json.keys).to include(*serializer_keys)
    end

    it 'serializes reported statuses' do
      status = Fabricate(:status)
      report.update!(status_ids: [status.id])

      get :show, params: { id: report.id }, format: :json

      expect(body_as_json[:statuses].map { |entry| entry[:id] }).to eq [status.id.to_s]
    end

    context 'with admin:read:reports scope' do
      let(:scopes) { 'admin:read:reports' }

      it 'returns http success' do
        get :show, params: { id: report.id }, format: :json
        expect(response).to have_http_status(200)
      end
    end
  end

  describe 'POST #resolve' do
    before do
      post :resolve, params: { id: report.id }, format: :json
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'returns action_taken as true' do
      post :resolve, params: { id: report.id }, format: :json

      expect(body_as_json[:action_taken]).to eq true
      expect(report.reload.action_taken_at).to be_present
      expect(body_as_json[:action_taken_at]).to be_present
    end
  end

  describe 'POST #reopen' do
    before do
      post :reopen, params: { id: report.id }, format: :json
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'clears action_taken_at for a resolved report' do
      report.resolve!(user.account)

      post :reopen, params: { id: report.id }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:action_taken]).to eq false
      expect(body_as_json[:action_taken_at]).to be_nil
      expect(report.reload.action_taken_at).to be_nil
    end
  end

  describe 'POST #assign_to_self' do
    before do
      post :assign_to_self, params: { id: report.id }, format: :json
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'assigns the current account' do
      expect(report.reload.assigned_account_id).to eq user.account.id
    end
  end

  describe 'POST #unassign' do
    before do
      post :unassign, params: { id: report.id }, format: :json
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'clears the assigned account' do
      report.update!(assigned_account_id: user.account.id)

      post :unassign, params: { id: report.id }, format: :json

      expect(report.reload.assigned_account_id).to be_nil
    end
  end

  describe 'PUT/PATCH #update' do # rubocop:disable Metrics/BlockLength
    it_behaves_like 'forbidden for wrong scope', 'write:statuses' do
      before { put :update, params: { id: report.id, category: 'spam' }, format: :json }
    end

    it_behaves_like 'forbidden for wrong role', 'user' do
      before { put :update, params: { id: report.id, category: 'spam' }, format: :json }
    end

    it 'updates category via PUT' do
      expect { put :update, params: { id: report.id, category: 'spam' }, format: :json }
        .to_not change(Admin::ActionLog, :count)

      expect(response).to have_http_status(200)
      expect(body_as_json[:category]).to eq 'spam'
      expect(report.reload).to be_spam
    end

    it 'updates category via PATCH' do
      patch :update, params: { id: report.id, category: 'legal' }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:category]).to eq 'legal'
      expect(report.reload).to be_legal
    end

    it 'attaches valid rules to a violation report' do
      rule1 = Fabricate(:rule, deleted_at: nil, priority: 0)
      rule2 = Fabricate(:rule, deleted_at: nil, priority: 1)

      put :update, params: { id: report.id, category: 'violation', rule_ids: [rule1.id, rule2.id] }, format: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:category]).to eq 'violation'
      expect(report.reload.rule_ids).to eq [rule1.id, rule2.id]
      expect(body_as_json[:rules].map { |entry| entry[:id] }).to contain_exactly(rule1.id.to_s, rule2.id.to_s)
      expect(body_as_json[:rules].map { |entry| entry[:id] }).to all(be_a(String))
    end

    it 'returns 422 for a nonexistent rule' do
      put :update, params: { id: report.id, category: 'violation', rule_ids: [-1] }, format: :json

      expect(response).to have_http_status(422)
    end

    it 'returns 422 for a violation without rules' do
      put :update, params: { id: report.id, category: 'violation' }, format: :json

      expect(response).to have_http_status(422)
    end

    it 'returns 422 when a non-violation category includes rule ids' do
      rule = Fabricate(:rule, deleted_at: nil, priority: 0)

      put :update, params: { id: report.id, category: 'spam', rule_ids: [rule.id] }, format: :json

      expect(response).to have_http_status(422)
    end

    it 'does not change fields outside category and rule_ids' do
      original_comment = report.comment

      put :update, params: { id: report.id, category: 'spam', comment: 'hacked', forwarded: true }, format: :json

      expect(response).to have_http_status(200)
      expect(report.reload.comment).to eq original_comment
      expect(report.forwarded).to be_nil
    end

    it 'returns http not found for a missing report' do
      put :update, params: { id: -1, category: 'spam' }, format: :json

      expect(response).to have_http_status(404)
    end

    context 'with admin:write scope' do
      let(:scopes) { 'admin:write' }

      it 'returns http success' do
        put :update, params: { id: report.id, category: 'spam' }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with admin:write:reports scope' do
      let(:scopes) { 'admin:write:reports' }

      it 'returns http success' do
        put :update, params: { id: report.id, category: 'spam' }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'with a read-only scope' do
      let(:scopes) { 'admin:read' }

      it 'returns http forbidden' do
        put :update, params: { id: report.id, category: 'spam' }, format: :json
        expect(response).to have_http_status(403)
      end
    end

    context 'as an enabled admin' do
      let(:role) { 'admin' }

      it 'returns http success' do
        put :update, params: { id: report.id, category: 'spam' }, format: :json
        expect(response).to have_http_status(200)
      end
    end

    context 'without a token' do
      let(:token) { nil }

      it 'returns http unauthorized' do
        put :update, params: { id: report.id, category: 'spam' }, format: :json
        expect(response).to have_http_status(401)
      end
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

    it 'forbids a disabled moderator from updating reports' do
      put :update, params: { id: report.id, category: 'spam' }, format: :json
      expect(response).to have_http_status(403)
    end

    context 'as a disabled admin' do
      let(:role) { 'admin' }

      it 'forbids reading reports with a valid admin token' do
        get :show, params: { id: report.id }, format: :json
        expect(response).to have_http_status(403)
      end

      it 'forbids updating reports with a valid admin token' do
        put :update, params: { id: report.id, category: 'spam' }, format: :json
        expect(response).to have_http_status(403)
      end
    end
  end
end
