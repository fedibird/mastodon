require 'rails_helper'

RSpec.describe Api::V1::Admin::AccountsController, type: :controller do
  render_views

  let(:role)   { 'moderator' }
  let(:user)   { user_with_legacy_role_name(role, account: Fabricate(:account, username: 'alice')) }
  let(:scopes) { 'admin:read admin:write' }
  let(:token)  { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:account) { Fabricate(:user).account }

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
      get :show, params: { id: account.id }
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end
  end

  describe 'GET #show ips and sensitized' do
    it 'returns aggregated IPs and a false sensitized flag' do
      target = Fabricate(:user)
      target.update_columns(sign_up_ip: '192.0.2.10', created_at: Time.utc(2026, 9, 1, 8, 0, 0))
      SessionActivation.activate(session_id: SecureRandom.hex(16), user: target, ip: '192.0.2.20')

      get :show, params: { id: target.account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:sensitized]).to be false
      expect(body_as_json[:ips].map { |row| row[:ip] }).to contain_exactly('192.0.2.10', '192.0.2.20')
      expect(body_as_json[:ips]).to all(include(:ip, :used_at))
      body_as_json[:ips].each { |row| expect { DateTime.rfc3339(row[:used_at]) }.not_to raise_error }
      expect(body_as_json[:ip]).to eq(body_as_json[:ips].first[:ip])
    end

    it 'returns sensitized true after the account is sensitized' do
      target = Fabricate(:user)
      target.account.sensitize!

      get :show, params: { id: target.account.id }

      expect(body_as_json[:sensitized]).to be true
    end

    it 'returns no IPs for a remote account' do
      remote = Fabricate(:account, domain: 'example.com', username: 'remote')

      get :show, params: { id: remote.id }

      expect(body_as_json[:role]).to be_nil
      expect(body_as_json[:ips]).to be_blank
      expect(body_as_json[:ip]).to be_nil
      expect(body_as_json[:sensitized]).to be false
    end
  end

  describe 'GET #show role entity' do
    it 'returns the Owner role entity when role_id is Owner' do
      owner = user_with_role('Owner')

      get :show, params: { id: owner.account.id }

      role = body_as_json[:role]
      expect(response).to have_http_status(200)
      expect(role).to be_a(Hash)
      expect(role[:name]).to eq 'Owner'
      expect(role[:permissions]).to eq UserRole::Flags::ALL.to_s
      expect(body_as_json[:email]).to eq owner.email
      expect(body_as_json).to include(:ip, :invite_request, :silenced, :confirmed)
      expect(body_as_json[:silenced]).to be false
    end

    it 'returns a custom role entity' do
      custom = UserRole.create!(name: 'Helper', position: 5, permissions_as_keys: %w(manage_reports), color: '#123456', highlighted: true)
      target = Fabricate(:user, admin: false, moderator: false)
      target.update_columns(role_id: custom.id)

      get :show, params: { id: target.account.id }

      role = body_as_json[:role]
      expect(role[:id]).to eq custom.id.to_s
      expect(role[:name]).to eq 'Helper'
      expect(role[:color]).to eq '#123456'
      expect(role[:highlighted]).to be true
      expect(role[:permissions]).to eq target.role.computed_permissions.to_s
      expect(body_as_json[:email]).to eq target.email
    end

    it 'returns a null role for a remote account' do
      remote = Fabricate(:account, domain: 'remote.example', username: 'bob')

      get :show, params: { id: remote.id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:role]).to be_nil
      expect(body_as_json[:username]).to eq 'bob'
      expect(body_as_json[:domain]).to eq 'remote.example'
    end

    it 'returns a null role for a local account without a user' do
      local = Fabricate(:account, username: 'ghost')

      get :show, params: { id: local.id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:role]).to be_nil
      expect(body_as_json[:email]).to be_nil
    end
  end

  describe 'GET #index assigned roles' do
    it 'preloads assigned roles instead of looking each role up by id' do
      everyone = UserRole.everyone
      allow(UserRole).to receive(:everyone).and_return(everyone)

      actor = User.includes(:role).find(user.id)
      allow(User).to receive(:find).and_wrap_original do |method, *args|
        args.first == user.id ? actor : method.call(*args)
      end

      2.times do |index|
        role = UserRole.create!(name: "Helper #{index}", position: index + 1, permissions_as_keys: %w(manage_reports))
        record = Fabricate(:user, admin: false, moderator: false)
        record.update_columns(role_id: role.id)
      end

      queries = []
      callback = lambda do |*_args, payload|
        queries << payload[:sql]
      end

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        get :index
      end

      role_selects = queries.select { |sql| sql.include?('"user_roles"') && sql.match?(/\ASELECT/i) }
      point_lookups = role_selects.grep(/"user_roles"\."id"\s*=/)

      expect(response).to have_http_status(200)
      expect(point_lookups).to be_empty
      expect(role_selects.join("\n")).to include('"user_roles"."id" IN')
      expect(body_as_json.map { |row| row.dig(:role, :name) }).to include('Helper 0', 'Helper 1', 'Moderator')
    end

    it 'preloads user IPs instead of querying each account' do
      2.times do |index|
        record = Fabricate(:user)
        record.update_columns(sign_up_ip: "192.0.2.#{index + 10}")
      end

      queries = []
      callback = lambda do |*_args, payload|
        queries << payload[:sql]
      end

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        get :index
      end

      ip_selects = queries.select { |sql| sql.include?('"user_ips"') && sql.match?(/\ASELECT/i) }
      point_lookups = ip_selects.grep(/"user_ips"\."user_id"\s*=/)

      expect(response).to have_http_status(200)
      expect(ip_selects).not_to be_empty
      expect(point_lookups).to be_empty
      expect(ip_selects.join("\n")).to match(/"user_ips"\."user_id" IN/)
    end
  end

  describe 'POST #approve' do
    before do
      account.user.update(approved: false)
      post :approve, params: { id: account.id }
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'approves user' do
      expect(account.reload.user_approved?).to be true
    end
  end

  describe 'POST #reject' do
    before do
      account.user.update(approved: false)
      post :reject, params: { id: account.id }
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'removes user' do
      expect(User.where(id: account.user.id).count).to eq 0
    end
  end

  describe 'POST #enable' do
    before do
      account.user.update(disabled: true)
      post :enable, params: { id: account.id }
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'enables user' do
      expect(account.reload.user_disabled?).to be false
    end
  end

  describe 'POST #unsuspend' do
    before do
      account.suspend!
      post :unsuspend, params: { id: account.id }
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'unsuspends account' do
      expect(account.reload.suspended?).to be false
    end
  end

  describe 'POST #unsensitive' do
    before do
      account.touch(:sensitized_at)
      post :unsensitive, params: { id: account.id }
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'unsensitives account' do
      expect(account.reload.sensitized?).to be false
    end
  end

  describe 'POST #unsilence' do
    before do
      account.touch(:silenced_at)
      post :unsilence, params: { id: account.id }
    end

    it_behaves_like 'forbidden for wrong scope', 'write:statuses'
    it_behaves_like 'forbidden for wrong role', 'user'

    it 'returns http success' do
      expect(response).to have_http_status(200)
    end

    it 'unsilences account' do
      expect(account.reload.silenced?).to be false
    end
  end

  describe 'disabled staff' do
    before { user.disable! }

    it 'forbids a disabled moderator from reading accounts' do
      get :index, format: :json
      expect(response).to have_http_status(403)
    end

    it 'forbids a disabled moderator from writing accounts' do
      post :unsilence, params: { id: account.id }, format: :json
      expect(response).to have_http_status(403)
    end

    context 'as a disabled admin' do
      let(:role) { 'admin' }

      it 'forbids reading accounts with a valid admin token' do
        get :index, format: :json
        expect(response).to have_http_status(403)
      end

      it 'forbids writing accounts with a valid admin token' do
        post :unsilence, params: { id: account.id }, format: :json
        expect(response).to have_http_status(403)
      end
    end
  end
end
