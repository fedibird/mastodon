# frozen_string_literal: true

require 'rails_helper'

describe InvitesController do # rubocop:disable Metrics/BlockLength
  render_views

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end

  before do
    stub_webpacker_manifest
    sign_in user
  end

  def set_everyone_invite(enabled)
    flag = UserRole::FLAGS[:invite_users]
    everyone = UserRole.everyone
    permissions = if enabled
                    everyone.permissions | flag
                  else
                    everyone.permissions & ~flag
                  end
    everyone.update!(permissions: permissions)
  end

  describe 'GET #index' do
    subject { get :index }

    let(:user) { Fabricate(:user, moderator: false, admin: false) }
    let!(:invite) { Fabricate(:invite, user: user) }

    context 'when Everyone can invite' do
      it 'renders index page' do
        set_everyone_invite(true)
        expect(subject).to render_template :index
        expect(assigns(:invites)).to include invite
        expect(assigns(:invites).count).to eq 1
      end
    end

    context 'when the user role cannot invite' do
      it 'returns 403' do
        set_everyone_invite(false)
        expect(subject).to have_http_status 403
      end
    end
  end

  describe 'POST #create' do
    subject { post :create, params: { invite: { max_uses: '10', expires_in: 1800 } } }

    context 'when user is an admin' do
      let(:user) { Fabricate(:user, moderator: false, admin: true) }

      it 'succeeds to create a invite' do
        expect { subject }.to change { Invite.count }.by(1)
        expect(subject).to redirect_to invites_path
        expect(Invite.last).to have_attributes(user_id: user.id, max_uses: 10)
      end
    end

    context 'when user is not an admin' do
      let(:user) { Fabricate(:user, moderator: true, admin: false) }

      it 'returns 403' do
        set_everyone_invite(false)
        expect(subject).to have_http_status 403
      end
    end
  end

  describe 'POST #create with action review' do
    let(:user) { Fabricate(:user, moderator: false, admin: true) }

    around do |example|
      example.run
    ensure
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end

    def store_always
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'invite_creation' => 'always' }
      )
      Rails.cache.clear
    end

    it 'redirects with a pending notice and does not reveal the code' do
      store_always

      post :create, params: { invite: { max_uses: '10', expires_in: 1800, comment: 'hidden-note' } }

      invite = Invite.last
      expect(response).to redirect_to invites_path
      expect(flash[:notice]).to eq I18n.t('invites.pending_review')
      expect(invite.valid_for_use?).to be false
      expect(ActionReviewRequest.last.resource).to eq invite

      get :index

      expect(response.body).to include(I18n.t('invites.review.waiting'))
      expect(response.body).not_to include(invite.code)
      expect(response.body).not_to include('hidden-note')
      expect(response.body).not_to include(I18n.t('invites.delete'))
    end

    it 're-renders the list when the invite is invalid' do
      post :create, params: { invite: { max_uses: '10', expires_in: 1800, comment: 'x' * 421 } }

      expect(response).to render_template(:index)
      expect(assigns(:invite).errors[:comment]).to be_present
      expect(Invite.count).to eq 0
      expect(ActionReviewRequest.count).to eq 0
    end
  end

  describe 'GET #index review rows' do # rubocop:disable Metrics/BlockLength
    let(:user) { Fabricate(:user, moderator: false, admin: true) }

    it 'shows a stopped row without the code and leaves an ordinary invite unchanged' do
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'invite_creation' => 'always' }
      )
      Rails.cache.clear
      held = InviteCreation::CreateService.new.call(user: user, attributes: { max_uses: 1, expires_in: 1800 })
      ActionReview::DecisionService.new.call(
        request: held.request,
        decision: 'reject',
        reviewer_account: user.account,
        decision_note: nil
      )
      ordinary = Fabricate(:invite, user: user, expires_at: nil)

      get :index

      expect(response.body).to include(I18n.t('invites.review.stopped'))
      expect(response.body).not_to include(held.invite.code)
      expect(response.body).to include(ordinary.code)
    ensure
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end

    it 'hides the code, url, and copy control for a cancelled review' do
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'invite_creation' => 'always' }
      )
      Rails.cache.clear
      held = InviteCreation::CreateService.new.call(user: user, attributes: { max_uses: 1, expires_in: 1800 })
      held.request.update!(state: :cancelled)

      get :index

      expect(response.body).to include(I18n.t('invites.review.stopped'))
      expect(response.body).not_to include(held.invite.code)
      expect(response.body).not_to include('input-copy')
      expect(response.body).not_to include(I18n.t('invites.delete'))
    ensure
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end

    it 'shows the public url again after approval' do
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'invite_creation' => 'always' }
      )
      Rails.cache.clear
      held = InviteCreation::CreateService.new.call(user: user, attributes: { max_uses: 1, expires_in: '' })
      ActionReview::DecisionService.new.call(
        request: held.request,
        decision: 'approve',
        reviewer_account: user.account,
        decision_note: nil
      )

      get :index

      expect(response.body).to include(held.invite.reload.code)
      expect(response.body).to include(I18n.t('generic.copy'))
    ensure
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end
  end

  describe 'DELETE #destroy pending shell' do
    let(:user) { Fabricate(:user, moderator: false, admin: true) }

    it 'does not approve the review or make the code usable' do
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'invite_creation' => 'always' }
      )
      Rails.cache.clear
      held = InviteCreation::CreateService.new.call(user: user, attributes: { max_uses: 1, expires_in: 1800 })

      delete :destroy, params: { id: held.invite.id }

      expect(response).to redirect_to invites_path
      expect(held.invite.reload.valid_for_use?).to be false
      expect(held.request.reload.pending_state?).to be true
    ensure
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end
  end

  describe 'DELETE #destroy cancelled shell' do
    let(:user) { Fabricate(:user, moderator: false, admin: true) }

    it 'does not move expires_at or make the code usable' do
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'invite_creation' => 'always' }
      )
      Rails.cache.clear
      held = InviteCreation::CreateService.new.call(user: user, attributes: { max_uses: 1, expires_in: 1800 })
      held.request.update!(state: :cancelled)
      expires_at = held.invite.expires_at

      delete :destroy, params: { id: held.invite.id }

      fresh = held.invite.reload
      expect(response).to redirect_to invites_path
      expect(fresh.expires_at.to_i).to eq expires_at.to_i
      expect(fresh.valid_for_use?).to be false
      expect(held.request.reload.cancelled_state?).to be true
    ensure
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end
  end

  describe 'DELETE #create' do
    subject { delete :destroy, params: { id: invite.id } }

    let!(:invite) { Fabricate(:invite, user: user, expires_at: nil) }
    let(:user) { Fabricate(:user, moderator: false, admin: true) }

    it 'expires invite' do
      expect(subject).to redirect_to invites_path
      expect(invite.reload).to be_expired
    end
  end
end
