# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Admin::AccountsController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user)   { user_with_role('Moderator') }
  let(:scopes) { 'admin:read admin:write' }
  let(:token)  { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  def account_ids
    body_as_json.map { |row| row[:id] }
  end

  describe 'GET #index staff filter' do # rubocop:disable Metrics/BlockLength
    it 'returns Moderator and Owner accounts and keeps the role entity' do
      owner = user_with_role('Owner')

      get :index, params: { staff: 'true' }

      expect(response).to have_http_status(200)
      expect(account_ids).to include(user.account.id.to_s, owner.account.id.to_s)
      owner_row = body_as_json.find { |row| row[:id] == owner.account.id.to_s }
      expect(owner_row[:role]).to include(name: 'Owner')
      expect(owner_row[:role][:permissions]).to eq UserRole::Flags::ALL.to_s
    end

    it 'returns the default Admin role and a custom manage_reports role' do
      admin_user = user_with_role(UserRole.find_by!(name: 'Admin'))
      reporter = user_with_role(UserRole.create!(name: 'Reporter', position: 4, permissions_as_keys: %w(manage_reports)))

      get :index, params: { staff: 'true' }

      expect(account_ids).to include(admin_user.account.id.to_s, reporter.account.id.to_s)
      reporter_row = body_as_json.find { |row| row[:id] == reporter.account.id.to_s }
      expect(reporter_row[:role][:name]).to eq 'Reporter'
    end

    it 'excludes ordinary users and roles that cannot manage reports' do
      ordinary = Fabricate(:user)
      user_admin = user_with_role(UserRole.create!(name: 'User admin', position: 6, permissions_as_keys: %w(manage_users)))
      devops = user_with_role(UserRole.create!(name: 'Devops', position: 7, permissions_as_keys: %w(view_devops)))

      get :index, params: { staff: 'true' }

      expect(account_ids).not_to include(ordinary.account.id.to_s, user_admin.account.id.to_s, devops.account.id.to_s)
    end

    it 'follows the assigned role when it disagrees with the legacy moderator flag' do
      viewer = UserRole.create!(name: 'Viewer', position: 8, permissions_as_keys: %w(view_devops))
      legacy_moderator = Fabricate(:user, moderator: true)
      legacy_moderator.update_columns(role_id: viewer.id)
      reporter = user_with_role(UserRole.create!(name: 'Reporter', position: 4, permissions_as_keys: %w(manage_reports)))

      expect(User).not_to respond_to(:staff)
      get :index, params: { staff: 'true' }

      expect(account_ids).not_to include(legacy_moderator.account.id.to_s)
      expect(account_ids).to include(reporter.account.id.to_s)
    end

    it 'keeps staff=true on the pagination link and omits internal role ids' do
      user_with_role('Owner')

      get :index, params: { staff: 'true', limit: 1 }

      link = response.headers['Link'].to_s
      expect(response).to have_http_status(200)
      expect(link).to include('rel="next"')
      expect(link).to include('staff=true')
      expect(link).not_to include('role_ids')
    end

    it 'does not accept role_ids as a public filter' do
      reporter = user_with_role(UserRole.create!(name: 'Reporter', position: 4, permissions_as_keys: %w(manage_reports)))
      ordinary = Fabricate(:user)

      get :index, params: { role_ids: [reporter.role.id] }

      expect(account_ids).to include(reporter.account.id.to_s, ordinary.account.id.to_s)
    end

    it 'still filters hard silenced accounts' do
      silenced = Fabricate(:user)
      silenced.account.hard_silence!
      audible = Fabricate(:user)

      get :index, params: { hard_silenced: '1' }

      expect(account_ids).to include(silenced.account.id.to_s)
      expect(account_ids).not_to include(audible.account.id.to_s, user.account.id.to_s)
    end
  end
end
