# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V2::Admin::AccountsController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user)   { Fabricate(:user, moderator: true) }
  let(:scopes) { 'admin:read admin:write' }
  let(:token)  { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  def account_ids
    body_as_json.map { |row| row[:id] }
  end

  def user_with_role(role)
    record = Fabricate(:user, admin: false, moderator: false)
    record.update_columns(role_id: role.id)
    record
  end

  it 'routes the v2 index helper' do
    expect(api_v2_admin_accounts_path).to eq '/api/v2/admin/accounts'
    expect(get: '/api/v2/admin/accounts').to route_to('api/v2/admin/accounts#index')
  end

  describe 'GET #index authorization' do
    it 'rejects the wrong OAuth scope' do
      unauthorized = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:statuses')
      allow(controller).to receive(:doorkeeper_token) { unauthorized }

      get :index

      expect(response).to have_http_status(403)
    end

    it 'rejects an ordinary user' do
      ordinary = Fabricate(:user)
      ordinary_token = Fabricate(:accessible_access_token, resource_owner_id: ordinary.id, scopes: scopes)
      allow(controller).to receive(:doorkeeper_token) { ordinary_token }

      get :index

      expect(response).to have_http_status(403)
    end

    it 'rejects a disabled moderator' do
      user.disable!

      get :index

      expect(response).to have_http_status(403)
    end
  end

  describe 'GET #index origin and status' do # rubocop:disable Metrics/BlockLength
    it 'returns local accounts for origin=local and remote accounts for origin=remote' do
      remote = Fabricate(:account, domain: 'example.org')

      get :index, params: { origin: 'local', status: 'active' }
      expect(account_ids).to include(user.account.id.to_s)
      expect(account_ids).not_to include(remote.id.to_s)

      get :index, params: { origin: 'remote' }
      expect(account_ids).to include(remote.id.to_s)
      expect(account_ids).not_to include(user.account.id.to_s)
    end

    it 'returns local and remote accounts when origin is omitted' do
      remote = Fabricate(:account, domain: 'example.org')
      suspended = Fabricate(:account, suspended: true)

      get :index

      expect(account_ids).to include(user.account.id.to_s, remote.id.to_s, suspended.id.to_s)
      expect(account_ids).not_to include('-99')
    end

    it 'filters each v2 status onto the Fedibird account scopes' do
      pending = Fabricate(:user)
      pending.update_columns(approved: false)
      disabled = Fabricate(:user, disabled: true)
      disabled_suspended = Fabricate(:user, disabled: true)
      disabled_suspended.account.suspend!
      silenced = Fabricate(:user)
      silenced.account.silence!
      hard_silenced = Fabricate(:user)
      hard_silenced.account.hard_silence!
      silenced_suspended = Fabricate(:user)
      silenced_suspended.account.silence!
      silenced_suspended.account.suspend!
      suspended = Fabricate(:account, suspended: true)
      remote_suspended = Fabricate(:account, domain: 'example.org', suspended: true)

      get :index, params: { origin: 'local', status: 'active' }
      expect(account_ids).to include(user.account.id.to_s)
      expect(account_ids).not_to include(suspended.id.to_s, disabled_suspended.account.id.to_s)

      get :index, params: { origin: 'local', status: 'pending' }
      expect(account_ids).to include(pending.account.id.to_s)
      expect(account_ids).not_to include(user.account.id.to_s)

      get :index, params: { origin: 'local', status: 'disabled' }
      expect(account_ids).to include(disabled.account.id.to_s)
      expect(account_ids).not_to include(disabled_suspended.account.id.to_s, user.account.id.to_s)

      get :index, params: { origin: 'local', status: 'silenced' }
      expect(account_ids).to include(silenced.account.id.to_s, hard_silenced.account.id.to_s, silenced_suspended.account.id.to_s)
      expect(account_ids).not_to include(user.account.id.to_s)

      get :index, params: { status: 'suspended' }
      expect(account_ids).to include(suspended.id.to_s, remote_suspended.id.to_s)
      expect(account_ids).not_to include(user.account.id.to_s)
    end

    it 'limits a remote domain with by_domain' do
      matched = Fabricate(:account, domain: 'example.org')
      other = Fabricate(:account, domain: 'other.example')

      get :index, params: { origin: 'remote', by_domain: 'example.org' }

      expect(account_ids).to eq [matched.id.to_s]
      expect(account_ids).not_to include(other.id.to_s, user.account.id.to_s)
    end

    it 'rejects an unknown origin' do
      get :index, params: { origin: 'elsewhere' }

      expect(response).to have_http_status(400)
    end
  end

  describe 'GET #index permissions and role_ids' do
    it 'returns roles that can manage reports and keeps the role entity' do
      owner = Fabricate(:user, admin: true)
      admin_user = user_with_role(UserRole.find_by!(name: 'Admin'))
      reporter = user_with_role(UserRole.create!(name: 'Reporter', position: 4, permissions_as_keys: %w(manage_reports)))
      user_admin = user_with_role(UserRole.create!(name: 'User admin', position: 6, permissions_as_keys: %w(manage_users)))
      devops = user_with_role(UserRole.create!(name: 'Devops', position: 7, permissions_as_keys: %w(view_devops)))
      ordinary = Fabricate(:user)

      expect(User).not_to respond_to(:staff)
      get :index, params: { permissions: 'staff', origin: 'local', status: 'active' }

      expect(account_ids).to include(user.account.id.to_s, owner.account.id.to_s, admin_user.account.id.to_s, reporter.account.id.to_s)
      expect(account_ids).not_to include(user_admin.account.id.to_s, devops.account.id.to_s, ordinary.account.id.to_s)
      owner_row = body_as_json.find { |row| row[:id] == owner.account.id.to_s }
      expect(owner_row[:role]).to include(name: 'Owner')
      expect(owner_row[:role][:permissions]).to eq UserRole::Flags::ALL.to_s
      expect(owner_row[:email]).to eq owner.email
    end

    it 'filters one role, several roles, Everyone, and an unknown id' do
      admin_role = UserRole.find_by!(name: 'Admin')
      custom = UserRole.create!(name: 'Helper', position: 5, permissions_as_keys: %w(manage_reports))
      admin_user = user_with_role(admin_role)
      custom_user = user_with_role(custom)
      ordinary = Fabricate(:user)

      get :index, params: { role_ids: [custom.id], origin: 'local', status: 'active' }
      expect(account_ids).to eq [custom_user.account.id.to_s]

      get :index, params: { role_ids: [admin_role.id, custom.id], origin: 'local', status: 'active' }
      expect(account_ids).to include(admin_user.account.id.to_s, custom_user.account.id.to_s)
      expect(account_ids).not_to include(ordinary.account.id.to_s, user.account.id.to_s)

      get :index, params: { role_ids: ['-99'], origin: 'local', status: 'active' }
      expect(account_ids).to include(ordinary.account.id.to_s)
      expect(account_ids).not_to include(custom_user.account.id.to_s, user.account.id.to_s)

      get :index, params: { role_ids: ['-99', custom.id], origin: 'local', status: 'active' }
      expect(account_ids).to include(ordinary.account.id.to_s, custom_user.account.id.to_s)
      expect(account_ids).not_to include(user.account.id.to_s)

      get :index, params: { role_ids: ['999999999999'], origin: 'local', status: 'active' }
      expect(account_ids).to eq []
    end

    it 'lets permissions=staff replace an explicit role_ids filter' do
      devops_role = UserRole.create!(name: 'Devops', position: 7, permissions_as_keys: %w(view_devops))
      devops = user_with_role(devops_role)
      reporter = user_with_role(UserRole.create!(name: 'Reporter', position: 4, permissions_as_keys: %w(manage_reports)))

      get :index, params: { permissions: 'staff', role_ids: [devops_role.id], origin: 'local', status: 'active' }

      expect(account_ids).to include(user.account.id.to_s, reporter.account.id.to_s)
      expect(account_ids).not_to include(devops.account.id.to_s)
    end
  end

  describe 'GET #index invited_by and pagination' do
    it 'returns accounts invited by the given user' do
      inviter = Fabricate(:user)
      invite = Fabricate(:invite, user: inviter)
      invited = Fabricate(:user, invite: invite)
      other = Fabricate(:user)

      get :index, params: { invited_by: inviter.id, origin: 'local', status: 'active' }

      expect(account_ids).to eq [invited.account.id.to_s]
      expect(account_ids).not_to include(other.account.id.to_s, inviter.account.id.to_s)
    end

    it 'paginates with the v2 url and preserves role_ids' do
      first_role = UserRole.create!(name: 'Helper one', position: 4, permissions_as_keys: %w(manage_reports))
      second_role = UserRole.create!(name: 'Helper two', position: 5, permissions_as_keys: %w(manage_reports))
      user_with_role(first_role)
      user_with_role(second_role)

      get :index, params: { role_ids: [first_role.id, second_role.id], origin: 'local', status: 'active', limit: 1 }

      link = response.headers['Link'].to_s
      expect(response).to have_http_status(200)
      expect(link).to include('/api/v2/admin/accounts')
      expect(link).to include('rel="next"')
      expect(link).to include('limit=1')
      expect(link).to include(first_role.id.to_s)
      expect(link).to include(second_role.id.to_s)
      expect(link).to include('role_ids')
      expect(link).not_to include('/api/v1/admin/accounts')
    end
  end
end
