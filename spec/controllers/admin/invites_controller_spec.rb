# frozen_string_literal: true

require 'rails_helper'

describe Admin::InvitesController do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user) { Fabricate(:user, admin: true) }

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end

  before do
    stub_webpacker_manifest
    sign_in user, scope: :user
  end

  describe 'GET #index' do
    subject { get :index, params: { available: true } }

    let!(:invite) { Fabricate(:invite) }

    it 'renders index page' do
      expect(subject).to render_template :index
      expect(assigns(:invites)).to include invite
    end
  end

  describe 'POST #create' do
    subject { post :create, params: { invite: { max_uses: '10', expires_in: 1800 } } }

    it 'succeeds to create a invite' do
      expect { subject }.to change { Invite.count }.by(1)
      expect(subject).to redirect_to admin_invites_path
      expect(Invite.last).to have_attributes(user_id: user.id, max_uses: 10)
    end
  end

  describe 'DELETE #destroy' do
    let!(:invite) { Fabricate(:invite, expires_at: nil) }

    subject { delete :destroy, params: { id: invite.id } }

    it 'expires invite' do
      expect(subject).to redirect_to admin_invites_path
      expect(invite.reload).to be_expired
    end
  end

  describe 'POST #create with action review' do
    around do |example|
      example.run
    ensure
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end

    it 'uses the creation service and waits for approval' do
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'invite_creation' => 'always' }
      )
      Rails.cache.clear

      expect { post :create, params: { invite: { max_uses: '10', expires_in: 1800 } } }.to change { Invite.count }.by(1)

      invite = Invite.last
      expect(response).to redirect_to admin_invites_path
      expect(flash[:notice]).to eq I18n.t('invites.pending_review')
      expect(invite.user).to eq user
      expect(invite.valid_for_use?).to be false

      get :index

      expect(response.body).to include(I18n.t('invites.review.waiting'))
      expect(response.body).to include(admin_action_review_path(ActionReviewRequest.last))
      expect(response.body).not_to include(invite.code)
      expect(response.body).to include(I18n.t('admin.invites.filter.review_pending'))
    end
  end

  describe 'GET #index review filters' do
    it 'links a pending row to its review and hides a rejected code' do
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'invite_creation' => 'always' }
      )
      Rails.cache.clear
      pending = InviteCreation::CreateService.new.call(user: user, attributes: { max_uses: 1, expires_in: 1800 })
      rejected = InviteCreation::CreateService.new.call(user: user, attributes: { max_uses: 1, expires_in: 1800 })
      ActionReview::DecisionService.new.call(
        request: rejected.request,
        decision: 'reject',
        reviewer_account: user.account,
        decision_note: nil
      )

      get :index, params: { review_pending: '1' }

      expect(assigns(:invites).map(&:id)).to eq [pending.invite.id]
      expect(response.body).not_to include(pending.invite.code)

      get :index, params: { review_rejected: '1' }

      expect(assigns(:invites).map(&:id)).to eq [rejected.invite.id]
      expect(response.body).to include(I18n.t('admin.invites.review_stopped'))
      expect(response.body).not_to include(rejected.invite.code)
    ensure
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end
  end

  describe 'GET #index cancelled review' do
    it 'hides the code, url, and copy control' do
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'invite_creation' => 'always' }
      )
      Rails.cache.clear
      held = InviteCreation::CreateService.new.call(user: user, attributes: { max_uses: 1, expires_in: 1800 })
      held.request.update!(state: :cancelled)

      get :index

      expect(response.body).to include(I18n.t('admin.invites.review_stopped'))
      expect(response.body).not_to include(held.invite.code)
      expect(response.body).not_to include('input-copy')
      expect(response.body).not_to include(admin_action_review_path(held.request))
    ensure
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end
  end

  describe 'POST #deactivate_all' do
    it 'expires all invites, then redirects to admin_invites_path' do
      invites = Fabricate.times(2, :invite, expires_at: nil)

      post :deactivate_all

      invites.each do |invite|
        expect(invite.reload).to be_expired
      end

      expect(response).to redirect_to admin_invites_path
    end

    it 'leaves a pending review shell unusable' do
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'invite_creation' => 'always' }
      )
      Rails.cache.clear
      held = InviteCreation::CreateService.new.call(user: user, attributes: { max_uses: 1, expires_in: 1800 })
      expires_at = held.invite.expires_at

      post :deactivate_all

      expect(held.invite.reload.expires_at.to_i).to eq expires_at.to_i
      expect(held.invite.valid_for_use?).to be false
      expect(held.request.reload.pending_state?).to be true
    ensure
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end
  end
end
