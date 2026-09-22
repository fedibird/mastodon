require 'rails_helper'

RSpec.describe Auth::RegistrationsController, type: :controller do
  render_views

  before do
    stub_webpacker_manifest
    allow_any_instance_of(User).to receive(:send_devise_notification)
  end

  shared_examples 'checks for enabled registrations' do |path|
    around do |example|
      registrations_mode = Setting.registrations_mode
      example.run
      Setting.registrations_mode = registrations_mode
    end

    it 'redirects if it is in single user mode while it is open for registration' do
      Fabricate(:account)
      Setting.registrations_mode = 'open'
      expect(Rails.configuration.x).to receive(:single_user_mode).and_return(true)

      get path

      expect(response).to redirect_to '/'
    end

    it 'redirects if it is not open for registration while it is not in single user mode' do
      Setting.registrations_mode = 'none'
      expect(Rails.configuration.x).to receive(:single_user_mode).and_return(false)

      get path

      expect(response).to redirect_to '/'
    end
  end

  describe 'GET #edit' do
    it 'returns http success' do
      request.env["devise.mapping"] = Devise.mappings[:user]
      sign_in(Fabricate(:user))
      get :edit
      expect(response).to have_http_status(200)
    end
  end

  describe 'GET #update' do
    it 'returns http success' do
      request.env["devise.mapping"] = Devise.mappings[:user]
      sign_in(Fabricate(:user), scope: :user)
      post :update
      expect(response).to have_http_status(200)
    end

    context 'when suspended' do
      it 'returns http forbidden' do
        request.env["devise.mapping"] = Devise.mappings[:user]
        sign_in(Fabricate(:user, account_attributes: { username: 'test', suspended_at: Time.now.utc }), scope: :user)
        post :update
        expect(response).to have_http_status(403)
      end
    end
  end

  describe 'GET #new' do # rubocop:disable Metrics/BlockLength
    before do
      request.env["devise.mapping"] = Devise.mappings[:user]
    end

    context do
      around do |example|
        registrations_mode = Setting.registrations_mode
        example.run
        Setting.registrations_mode = registrations_mode
      end

      it 'returns http success' do
        Setting.registrations_mode = 'open'
        get :new
        expect(response).to have_http_status(200)
      end
    end

    context 'when the request IP is sign-up blocked' do
      around do |example|
        registrations_mode = Setting.registrations_mode
        example.run
        Setting.registrations_mode = registrations_mode
      end

      it 'redirects to the root path' do
        Setting.registrations_mode = 'open'
        Fabricate(:ip_block, ip: '192.0.2.123', severity: :sign_up_block)
        request.env['REMOTE_ADDR'] = '192.0.2.123'

        get :new

        expect(response).to redirect_to '/'
      end
    end

    context 'when the request IP is covered by a sign-up block CIDR' do
      around do |example|
        registrations_mode = Setting.registrations_mode
        example.run
        Setting.registrations_mode = registrations_mode
      end

      it 'redirects to the root path' do
        Setting.registrations_mode = 'open'
        Fabricate(:ip_block, ip: '192.0.2.0/24', severity: :sign_up_block)
        request.env['REMOTE_ADDR'] = '192.0.2.123'

        get :new

        expect(response).to redirect_to '/'
      end
    end

    context 'when the request IP requires approval' do
      around do |example|
        registrations_mode = Setting.registrations_mode
        example.run
        Setting.registrations_mode = registrations_mode
      end

      it 'returns http success' do
        Setting.registrations_mode = 'open'
        Fabricate(:ip_block, ip: '192.0.2.50', severity: :sign_up_requires_approval)
        request.env['REMOTE_ADDR'] = '192.0.2.50'

        get :new

        expect(response).to have_http_status(200)
      end
    end

    include_examples 'checks for enabled registrations', :new
  end

  describe 'POST #create' do # rubocop:disable Metrics/BlockLength
    let(:accept_language) { Rails.application.config.i18n.available_locales.sample.to_s }

    before do
      session[:registration_form_time] = 5.seconds.ago
    end

    around do |example|
      current_locale = I18n.locale
      example.run
      I18n.locale = current_locale
    end

    before { request.env["devise.mapping"] = Devise.mappings[:user] }

    context do
      around do |example|
        registrations_mode = Setting.registrations_mode
        example.run
        Setting.registrations_mode = registrations_mode
      end

      subject do
        Setting.registrations_mode = 'open'
        request.headers["Accept-Language"] = accept_language
        post :create, params: { user: { account_attributes: { username: 'test' }, email: 'test@example.com', password: '12345678', password_confirmation: '12345678', agreement: 'true' } }
      end

      it 'redirects to setup' do
        subject
        expect(response).to redirect_to auth_setup_path
      end

      it 'creates user' do
        subject
        user = User.find_by(email: 'test@example.com')
        expect(user).to_not be_nil
        expect(user.locale).to eq(accept_language)
      end
    end

    context 'when user has not agreed to terms of service' do
      around do |example|
        registrations_mode = Setting.registrations_mode
        example.run
        Setting.registrations_mode = registrations_mode
      end

      subject do
        Setting.registrations_mode = 'open'
        request.headers["Accept-Language"] = accept_language
        post :create, params: { user: { account_attributes: { username: 'test' }, email: 'test@example.com', password: '12345678', password_confirmation: '12345678', agreement: 'false' } }
      end

      it 'does not create user' do
        subject
        user = User.find_by(email: 'test@example.com')
        expect(user).to be_nil
      end
    end

    context 'approval-based registrations without invite' do
      around do |example|
        registrations_mode = Setting.registrations_mode
        example.run
        Setting.registrations_mode = registrations_mode
      end

      subject do
        Setting.registrations_mode = 'approved'
        request.headers["Accept-Language"] = accept_language
        post :create, params: { user: { account_attributes: { username: 'test' }, email: 'test@example.com', password: '12345678', password_confirmation: '12345678', agreement: 'true' } }
      end

      it 'redirects to setup' do
        subject
        expect(response).to redirect_to auth_setup_path
      end

      it 'creates user' do
        subject
        user = User.find_by(email: 'test@example.com')
        expect(user).to_not be_nil
        expect(user.locale).to eq(accept_language)
        expect(user.approved).to eq(false)
      end
    end

    context 'approval-based registrations with expired invite' do
      around do |example|
        registrations_mode = Setting.registrations_mode
        example.run
        Setting.registrations_mode = registrations_mode
      end

      subject do
        Setting.registrations_mode = 'approved'
        request.headers["Accept-Language"] = accept_language
        invite = Fabricate(:invite, max_uses: nil, expires_at: 1.hour.ago)
        post :create, params: { user: { account_attributes: { username: 'test' }, email: 'test@example.com', password: '12345678', password_confirmation: '12345678', 'invite_code': invite.code, agreement: 'true' } }
      end

      it 'redirects to setup' do
        subject
        expect(response).to redirect_to auth_setup_path
      end

      it 'creates user' do
        subject
        user = User.find_by(email: 'test@example.com')
        expect(user).to_not be_nil
        expect(user.locale).to eq(accept_language)
        expect(user.approved).to eq(false)
      end
    end

    context 'approval-based registrations with valid invite and required invite text' do
      around do |example|
        registrations_mode = Setting.registrations_mode
        require_invite_text = Setting.require_invite_text
        example.run
        Setting.require_invite_text = require_invite_text
        Setting.registrations_mode = registrations_mode
      end

      subject do
        inviter = Fabricate(:user, confirmed_at: 2.days.ago)
        Setting.registrations_mode = 'approved'
        Setting.require_invite_text = true
        request.headers["Accept-Language"] = accept_language
        invite = Fabricate(:invite, user: inviter, max_uses: nil, expires_at: 1.hour.from_now)
        post :create, params: { user: { account_attributes: { username: 'test' }, email: 'test@example.com', password: '12345678', password_confirmation: '12345678', 'invite_code': invite.code, agreement: 'true' } }
      end

      it 'redirects to setup' do
        subject
        expect(response).to redirect_to auth_setup_path
      end

      it 'creates user' do
        subject
        user = User.find_by(email: 'test@example.com')
        expect(user).to_not be_nil
        expect(user.locale).to eq(accept_language)
        expect(user.approved).to eq(true)
      end
    end

    it 'does nothing if user already exists' do
      Fabricate(:user, account: Fabricate(:account, username: 'test'))
      subject
    end

    context 'when the request IP is sign-up blocked' do
      around do |example|
        registrations_mode = Setting.registrations_mode
        example.run
        Setting.registrations_mode = registrations_mode
      end

      subject do
        Setting.registrations_mode = 'open'
        request.env['REMOTE_ADDR'] = '192.0.2.123'
        post :create, params: { user: { account_attributes: { username: 'test' }, email: 'test@example.com', password: '12345678', password_confirmation: '12345678', agreement: 'true' } }
      end

      before do
        Fabricate(:ip_block, ip: '192.0.2.123', severity: :sign_up_block)
      end

      it 'redirects to the root path' do
        subject
        expect(response).to redirect_to '/'
      end

      it 'does not create a user' do
        subject
        expect(User.find_by(email: 'test@example.com')).to be_nil
      end
    end

    context 'when the request IP is covered by a sign-up block CIDR' do
      around do |example|
        registrations_mode = Setting.registrations_mode
        example.run
        Setting.registrations_mode = registrations_mode
      end

      subject do
        Setting.registrations_mode = 'open'
        request.env['REMOTE_ADDR'] = '192.0.2.123'
        post :create, params: { user: { account_attributes: { username: 'test' }, email: 'test@example.com', password: '12345678', password_confirmation: '12345678', agreement: 'true' } }
      end

      before do
        Fabricate(:ip_block, ip: '192.0.2.0/24', severity: :sign_up_block)
      end

      it 'redirects to the root path' do
        subject
        expect(response).to redirect_to '/'
      end

      it 'does not create a user' do
        subject
        expect(User.find_by(email: 'test@example.com')).to be_nil
      end
    end

    context 'when the request IP requires approval' do
      around do |example|
        registrations_mode = Setting.registrations_mode
        example.run
        Setting.registrations_mode = registrations_mode
      end

      subject do
        Setting.registrations_mode = 'open'
        request.env['REMOTE_ADDR'] = '192.0.2.50'
        post :create, params: { user: { account_attributes: { username: 'test' }, email: 'test@example.com', password: '12345678', password_confirmation: '12345678', agreement: 'true' } }
      end

      before do
        Fabricate(:ip_block, ip: '192.0.2.50', severity: :sign_up_requires_approval)
      end

      it 'creates an unapproved user' do
        subject
        user = User.find_by(email: 'test@example.com')
        expect(user).to_not be_nil
        expect(user.approved).to eq(false)
      end
    end

    context 'when a valid invite is present but the IP is sign-up blocked' do
      around do |example|
        registrations_mode = Setting.registrations_mode
        example.run
        Setting.registrations_mode = registrations_mode
      end

      subject do
        Setting.registrations_mode = 'none'
        request.env['REMOTE_ADDR'] = '192.0.2.123'
        post :create, params: { user: { account_attributes: { username: 'test' }, email: 'test@example.com', password: '12345678', password_confirmation: '12345678', invite_code: invite.code, agreement: 'true' } }
      end

      let(:invite) { Fabricate(:invite) }

      before do
        Fabricate(:ip_block, ip: '192.0.2.123', severity: :sign_up_block)
      end

      it 'redirects to the root path' do
        subject
        expect(response).to redirect_to '/'
      end

      it 'does not create a user' do
        subject
        expect(User.find_by(email: 'test@example.com')).to be_nil
      end
    end

    include_examples 'checks for enabled registrations', :create
  end

  describe 'invite creation review codes' do # rubocop:disable Metrics/BlockLength
    let(:owner) do
      user = Fabricate(:user, admin: true)
      user.update!(approved: true)
      user
    end

    around do |example|
      registrations_mode = Setting.registrations_mode
      example.run
      Setting.registrations_mode = registrations_mode
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end

    before do
      request.env['devise.mapping'] = Devise.mappings[:user]
      Setting.registrations_mode = 'none'
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'invite_creation' => 'always' }
      )
      Rails.cache.clear
    end

    def held_invite(expires_in: 3600)
      InviteCreation::CreateService.new.call(user: owner, attributes: { max_uses: 1, expires_in: expires_in }).invite
    end

    def register_with(invite)
      post :create, params: {
        user: {
          account_attributes: { username: "person#{invite.id}" },
          email: "person#{invite.id}@example.com",
          password: '12345678',
          password_confirmation: '12345678',
          invite_code: invite.code,
          agreement: 'true',
        },
      }
    end

    it 'does not accept a pending shell' do
      invite = held_invite

      expect(invite.valid_for_use?).to be false
      expect(Invite.available).not_to include(invite)

      register_with(invite)

      expect(response).to redirect_to('/')
      expect(User.find_by(email: "person#{invite.id}@example.com")).to be_nil
      expect(invite.reload.uses).to eq 0
    end

    it 'accepts a code only after approval' do
      invite = held_invite(expires_in: '')
      ActionReview::DecisionService.new.call(
        request: ActionReviewRequest.find_by!(resource: invite),
        decision: 'approve',
        reviewer_account: owner.account,
        decision_note: nil
      )

      register_with(invite.reload)

      created = User.find_by(email: "person#{invite.id}@example.com")
      expect(created).to be_present
      expect(created.invite_id).to eq invite.id
      expect(invite.reload.uses).to eq 1
    end

    it 'does not accept a rejected shell' do
      invite = held_invite
      ActionReview::DecisionService.new.call(
        request: ActionReviewRequest.find_by!(resource: invite),
        decision: 'reject',
        reviewer_account: owner.account,
        decision_note: nil
      )

      register_with(invite)

      expect(response).to redirect_to('/')
      expect(User.find_by(email: "person#{invite.id}@example.com")).to be_nil
      expect(invite.reload.uses).to eq 0
      expect(invite.valid_for_use?).to be false
    end
  end

  describe 'DELETE #destroy' do
    let(:user) { Fabricate(:user) }

    before do
      request.env['devise.mapping'] = Devise.mappings[:user]
      sign_in(user, scope: :user)
      delete :destroy
    end

    it 'returns http not found' do
      expect(response).to have_http_status(:not_found)
    end

    it 'does not delete user' do
      expect(User.find(user.id)).to_not be_nil
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
