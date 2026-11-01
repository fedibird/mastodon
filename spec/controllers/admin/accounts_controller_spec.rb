require 'rails_helper'

RSpec.describe Admin::AccountsController, type: :controller do
  render_views

  before { sign_in current_user, scope: :user }

  def create_managed_group_account(username:)
    creation_request = GroupCreationRequest.create!(
      requester_account: Fabricate(:user).account,
      username: username,
      display_name: 'Managed group'
    )
    group = Fabricate(:account, username: username, actor_type: 'Group')
    ManagedGroup.create!(account: group, creation_request: creation_request, origin: :approved_request)
    group
  end

  describe 'GET #index' do
    let(:current_user) { user_with_role('Owner') }

    around do |example|
      default_per_page = Account.default_per_page
      Account.paginates_per 1
      example.run
      Account.paginates_per default_per_page
    end

    it 'filters with parameters' do
      new = AccountFilter.method(:new)

      expect(AccountFilter).to receive(:new) do |params|
        h = params.to_h

        expect(h[:local]).to eq '1'
        expect(h[:remote]).to eq '1'
        expect(h[:by_domain]).to eq 'domain'
        expect(h[:active]).to eq '1'
        expect(h[:silenced]).to eq '1'
        expect(h[:suspended]).to eq '1'
        expect(h[:username]).to eq 'username'
        expect(h[:display_name]).to eq 'display name'
        expect(h[:email]).to eq 'local-part@domain'
        expect(h[:ip]).to eq '0.0.0.42'

        new.call({})
      end

      get :index, params: {
        local: '1',
        remote: '1',
        by_domain: 'domain',
        active: '1',
        silenced: '1',
        suspended: '1',
        username: 'username',
        display_name: 'display name',
        email: 'local-part@domain',
        ip: '0.0.0.42'
      }
    end

    it 'paginates accounts' do
      Fabricate(:account)

      get :index, params: { page: 2 }

      accounts = assigns(:accounts)
      expect(accounts.count).to eq 1
      expect(accounts.klass).to be Account
    end

    it 'returns http success' do
      get :index
      expect(response).to have_http_status(200)
    end

    it 'lists a managed User-less Group as active without deleted styling' do
      group = create_managed_group_account(username: 'managedindex')

      get :index, params: { username: group.username }

      expect(response).to have_http_status(:ok)
      link = Nokogiri::HTML(response.body).at_css("a.name-tag[title='#{group.username}']")
      expect(link).to be_present
      expect(link['class'].split).not_to include('suspended')
    end
  end

  describe 'GET #show' do
    let(:current_user) { user_with_role('Owner') }
    let(:account) { Fabricate(:account, username: 'bob') }

    it 'returns http success' do
      get :show, params: { id: account.id }
      expect(response).to have_http_status(200)
    end

    context 'with an approved Group that has no login User' do
      let(:account) { create_managed_group_account(username: 'managedshow') }

      it 'shows its Group account fields, without login-only fields or a deleted label' do
        get :show, params: { id: account.id }

        expect(response).to have_http_status(:ok)
        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css('.dashboard__counters__text').text.strip).to eq(I18n.t('admin.accounts.group_without_login'))

        headers = doc.css('.inline-table th').map { |element| element.text.strip }
        expect(headers).to include(I18n.t('admin.accounts.type'), I18n.t('admin.accounts.priority'), I18n.t('admin.accounts.joined'))
        expect(headers).not_to include(I18n.t('admin.accounts.role'), I18n.t('admin.accounts.email'), I18n.t('admin.accounts.security'))
        expect(response.body).not_to include(person_admin_account_type_path(account.id), service_admin_account_type_path(account.id))
      end

      it 'prioritizes suspension status over the no-login label' do
        account.update!(suspended_at: Time.current)
        get :show, params: { id: account.id }

        expect(response).to have_http_status(:ok)
        expect(Nokogiri::HTML(response.body).at_css('.dashboard__counters__text').text.strip).to eq(I18n.t('admin.accounts.suspended'))
      end
    end

    context 'with a deleted local Person' do
      it 'continues to hide its account settings table' do
        get :show, params: { id: account.id }

        expect(Nokogiri::HTML(response.body).at_css('.dashboard__counters__text').text.strip).to eq(I18n.t('admin.accounts.deleted'))
        expect(Nokogiri::HTML(response.body).at_css('table.inline-table')).to be_nil
      end
    end

    context 'with an unmanaged User-less Group' do
      let(:account) { Fabricate(:account, username: 'unmanagedshow', actor_type: 'Group') }

      it 'retains the legacy deleted state without exposing the management table' do
        get :show, params: { id: account.id }

        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css('.dashboard__counters__text').text.strip).to eq(I18n.t('admin.accounts.deleted'))
        expect(doc.at_css('table.inline-table')).to be_nil
      end
    end

    context 'with a local Person that has a User' do
      let(:account) { Fabricate(:user).account }

      it 'keeps the normal login and email settings available' do
        get :show, params: { id: account.id }

        expect(response).to have_http_status(:ok)
        headers = Nokogiri::HTML(response.body).css('.inline-table th').map { |element| element.text.strip }
        expect(headers).to include(I18n.t('admin.accounts.role'), I18n.t('admin.accounts.email'), I18n.t('admin.accounts.security'))
      end
    end
  end

  describe 'POST #memorialize' do
    subject { post :memorialize, params: { id: account.id } }

    let(:current_user) { current_user_admin ? user_with_role('Owner') : Fabricate(:user) }
    let(:account) { Fabricate(:account, user: user) }
    let(:user) { target_user_admin ? user_with_role('Owner') : Fabricate(:user) }

    context 'when user is admin' do
      let(:current_user_admin) { true }

      context 'when target user is admin' do
        let(:target_user_admin) { true }

        it 'fails to memorialize account' do
          is_expected.to have_http_status :forbidden
          expect(account.reload).not_to be_memorial
        end
      end

      context 'when target user is not admin' do
        let(:target_user_admin) { false }

        it 'succeeds in memorializing account' do
          is_expected.to redirect_to admin_account_path(account.id)
          expect(account.reload).to be_memorial
        end
      end
    end

    context 'when user is not admin' do
      let(:current_user_admin) { false }

      context 'when target user is admin' do
        let(:target_user_admin) { true }

        it 'fails to memorialize account' do
          is_expected.to have_http_status :forbidden
          expect(account.reload).not_to be_memorial
        end
      end

      context 'when target user is not admin' do
        let(:target_user_admin) { false }

        it 'fails to memorialize account' do
          is_expected.to have_http_status :forbidden
          expect(account.reload).not_to be_memorial
        end
      end
    end
  end

  describe 'POST #enable' do
    subject { post :enable, params: { id: account.id } }

    let(:current_user) { admin ? user_with_role('Owner') : Fabricate(:user) }
    let(:account) { Fabricate(:account, user: user) }
    let(:user) { Fabricate(:user, disabled: true) }

    context 'when user is admin' do
      let(:admin) { true }

      it 'succeeds in enabling account' do
        is_expected.to redirect_to admin_account_path(account.id)
        expect(user.reload).not_to be_disabled
      end
    end

    context 'when user is not admin' do
      let(:admin) { false }

      it 'fails to enable account' do
        is_expected.to have_http_status :forbidden
        expect(user.reload).to be_disabled
      end
    end
  end

  describe 'POST #redownload' do
    subject { post :redownload, params: { id: account.id } }

    let(:current_user) { admin ? user_with_role('Owner') : Fabricate(:user) }
    let(:account) { Fabricate(:account) }

    context 'when user is admin' do
      let(:admin) { true }

      it 'succeeds in redownloadin' do
        is_expected.to redirect_to admin_account_path(account.id)
      end
    end

    context 'when user is not admin' do
      let(:admin) { false }

      it 'fails to redownload' do
        is_expected.to have_http_status :forbidden
      end
    end
  end

  describe 'POST #remove_avatar' do
    subject { post :remove_avatar, params: { id: account.id } }

    let(:current_user) { admin ? user_with_role('Owner') : Fabricate(:user) }
    let(:account) { Fabricate(:account) }

    context 'when user is admin' do
      let(:admin) { true }

      it 'succeeds in removing avatar' do
        is_expected.to redirect_to admin_account_path(account.id)
      end
    end

    context 'when user is not admin' do
      let(:admin) { false }

      it 'fails to remove avatar' do
        is_expected.to have_http_status :forbidden
      end
    end

    context 'with a managed Group without a User' do
      let(:admin) { true }
      let(:account) { create_managed_group_account(username: 'managedmedia') }

      it 'logs moderation against the Group Account instead of a nil User' do
        expect { subject }.to change(Admin::ActionLog, :count).by(1)
        expect(response).to redirect_to(admin_account_path(account.id))
        expect(Admin::ActionLog.find_by!(target: account, action: 'remove_avatar')).to be_present
      end
    end
  end

  describe 'POST #remove_header' do
    let(:current_user) { user_with_role('Owner') }

    it 'logs header removal against a managed Group Account when there is no User' do
      account = create_managed_group_account(username: 'managedheader')

      post :remove_header, params: { id: account.id }

      expect(response).to redirect_to(admin_account_path(account.id))
      expect(Admin::ActionLog.find_by!(target: account, action: 'remove_header')).to be_present
    end
  end
end
