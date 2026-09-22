# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ActionReviewsController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:admin) { Fabricate(:user, admin: true) }

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end

  def fabricate_request(**attrs)
    actor = attrs.delete(:actor_account) { Fabricate(:account) }
    resource = attrs.delete(:resource) { Fabricate(:account) }
    ActionReviewRequest.create!(
      {
        operation_type: 'invite_creation',
        state: :pending,
        actor_account: actor,
        resource: resource,
        trigger: 'policy',
        signal_level: 'none',
        policy_mode: 'always',
        policy_version: 'action-review-policy-v1',
        reason_codes: ['policy_always'],
        evidence: { 'note' => 'factual' },
        requested_at: Time.now.utc,
      }.merge(attrs)
    )
  end

  before do
    stub_webpacker_manifest
  end

  describe 'authorization' do
    let!(:review_request) { fabricate_request }

    it 'allows a moderator to view index and show' do
      sign_in Fabricate(:user, moderator: true), scope: :user

      get :index
      expect(response).to have_http_status(200)

      get :show, params: { id: review_request }
      expect(response).to have_http_status(200)
    end

    it 'allows an admin to view index and show' do
      sign_in admin, scope: :user

      get :index
      expect(response).to have_http_status(200)

      get :show, params: { id: review_request }
      expect(response).to have_http_status(200)
    end

    it 'forbids an ordinary user' do
      sign_in Fabricate(:user), scope: :user

      get :index
      expect(response).to have_http_status(:forbidden)

      get :show, params: { id: review_request }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET #index' do
    before { sign_in admin, scope: :user }

    it 'defaults to pending, oldest first' do
      older = fabricate_request(requested_at: 2.days.ago)
      newer = fabricate_request(requested_at: 1.day.ago)
      fabricate_request(state: :approved, requested_at: 3.days.ago, resource: Fabricate(:account))

      get :index

      expect(assigns(:action_review_requests).map(&:id)).to eq [older.id, newer.id]
      expect(response).to have_http_status(200)
    end

    it 'filters by state and shows all' do
      pending_row = fabricate_request
      approved_row = fabricate_request(state: :approved, resource: Fabricate(:account))

      get :index, params: { state: 'approved' }
      expect(assigns(:action_review_requests).map(&:id)).to eq [approved_row.id]

      get :index, params: { state: 'all' }
      expect(assigns(:action_review_requests).map(&:id)).to include(pending_row.id, approved_row.id)
    end

    it 'uses kaminari pagination' do
      fabricate_request

      get :index, params: { page: 2 }

      expect(assigns(:action_review_requests).current_page).to eq 2
      expect(assigns(:action_review_requests).limit_value).to eq 40
    end

    it 'renders a deleted actor safely and does not print evidence' do
      actor = Fabricate(:account)
      request = fabricate_request(actor_account: actor, evidence: { 'secret' => 'evidence-token-xyz' })
      actor.delete

      get :index

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('admin.action_reviews.account_unavailable'))
      expect(response.body).not_to include('evidence-token-xyz')
      expect(response.body).to include('time class="formatted"')
      expect(response.body).to include(request.requested_at.iso8601)
    end

    it 'shows a pending count in navigation when pending rows exist' do
      fabricate_request
      fabricate_request

      get :index

      expect(response.body).to include(I18n.t('admin.action_reviews.title_with_count', count: 2))
    end

    it 'does not show a zero pending count' do
      get :index

      expect(response.body).to include(I18n.t('admin.action_reviews.title'))
      expect(response.body).not_to include(I18n.t('admin.action_reviews.title_with_count', count: 0))
    end
  end

  describe 'GET #show' do # rubocop:disable Metrics/BlockLength
    before { sign_in admin, scope: :user }

    it 'displays the audit snapshot with escaped evidence and local times' do
      request = fabricate_request(
        evidence: { 'note' => '<script>alert(1)</script>' },
        reason_codes: %w(policy_always evaluator_unavailable),
        evaluator_version: 'eval-v1'
      )

      get :show, params: { id: request }

      expect(response).to have_http_status(200)
      expect(response.body).to include('policy_always')
      expect(response.body).to include('evaluator_unavailable')
      expect(response.body).to include('eval-v1')
      expect(response.body).to include('action-review-policy-v1')
      expect(response.body).to include("#{request.resource_type} ##{request.resource_id}")
      expect(response.body).to include('time class="formatted"')
      expect(response.body).to include(request.requested_at.iso8601)
      expect(response.body).not_to include('<script>alert(1)</script>')
      expect(response.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
    end

    it 'does not display a stored follow import shadow signal' do
      owner = Fabricate(:account)
      batch = FollowImportBatch.create!(
        subject: ModerationSubject.for_account!(owner),
        imported_at: Time.now.utc,
        mode: :merge,
        dispatch_cohort: :operational,
        preflight_state: :review_required,
        target_count: 1,
        resolved_target_count: 1,
        unresolved_target_count: 0,
        metadata: {
          'review_signal_shadow_v1' => {
            'signal_level' => 'high',
            'classifier_version' => 'follow-import-review-signal-shadow-v1',
            'marker' => 'shadow-token-zx91',
          },
        }
      )
      request = fabricate_request(
        operation_type: 'follow_import',
        resource: batch,
        actor_account: owner,
        signal_level: 'none',
        evidence: { 'schema_version' => 1, 'batch_id' => batch.id }
      )

      get :show, params: { id: request }

      expect(response.body).to include(I18n.t('admin.action_reviews.signals.none'))
      expect(response.body).not_to include('follow-import-review-signal-shadow-v1')
      expect(response.body).not_to include('shadow-token-zx91')

      get :index

      expect(response.body).not_to include('follow-import-review-signal-shadow-v1')
      expect(response.body).not_to include('shadow-token-zx91')
    end

    it 'tolerates deleted actor, reviewer, and resource' do
      actor = Fabricate(:account)
      reviewer = Fabricate(:account)
      resource = Fabricate(:account)
      request = fabricate_request(
        actor_account: actor,
        resource: resource,
        state: :approved,
        reviewer_account: reviewer,
        reviewed_at: Time.now.utc,
        decision_note: 'recorded'
      )
      actor.delete
      reviewer.delete
      resource.delete

      get :show, params: { id: request }

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('admin.action_reviews.account_unavailable'))
      expect(response.body).to include("Account ##{resource.id}")
      expect(response.body).to include('recorded')
    end

    it 'routes approve and reject to the action review controller' do
      request = fabricate_request

      %w(approve reject).each do |action|
        recognized = Rails.application.routes.recognize_path("/admin/action_reviews/#{request.id}/#{action}", method: :post)
        expect(recognized[:controller]).to eq 'admin/action_reviews'
        expect(recognized[:action]).to eq action
      end
    end
  end

  describe 'decisions' do # rubocop:disable Metrics/BlockLength
    def held_follow_request(preflight_state: :review_required, state: :pending, operation_type: 'follow_import')
      owner = Fabricate(:account)
      import = Import.create!(account: owner, type: 'following', data: attachment_fixture('new-following-imports.txt'))
      batch = FollowImportBatch.create!(
        subject: ModerationSubject.for_account!(owner),
        import_id: import.id,
        imported_at: Time.now.utc,
        mode: :merge,
        dispatch_owner: :legacy,
        dispatch_cohort: :operational,
        preflight_state: preflight_state,
        target_count: 1,
        resolved_target_count: 1,
        unresolved_target_count: 0
      )
      fabricate_request(
        operation_type: operation_type,
        resource: batch,
        state: state,
        actor_account: owner,
        evidence: { 'schema_version' => 1, 'batch_id' => batch.id }
      )
    end

    before do
      allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
      allow(Import::RelationshipWorker).to receive(:perform_async)
    end

    it 'shows approve and stop controls for a pending follow import' do
      sign_in admin, scope: :user
      request = held_follow_request

      get :show, params: { id: request }

      expect(response.body).to include(I18n.t('admin.action_reviews.approve_and_run'))
      expect(response.body).to include(I18n.t('admin.action_reviews.stop'))
      expect(response.body).to include('data-confirm')
      expect(response.body).to include(I18n.t('admin.action_reviews.stop_confirm'))
      expect(response.body).to include('decision_note')
    end

    it 'does not show controls for a terminal or unsupported request' do
      sign_in admin, scope: :user
      terminal = held_follow_request(state: :approved, preflight_state: :ready)
      unsupported = fabricate_request

      get :show, params: { id: terminal }
      expect(response.body).not_to include(I18n.t('admin.action_reviews.approve_and_run'))

      get :show, params: { id: unsupported }
      expect(response.body).not_to include(I18n.t('admin.action_reviews.approve_and_run'))
      expect(response.body).not_to include(I18n.t('admin.action_reviews.stop_confirm'))
    end

    it 'warns and hides controls when the follow import is not waiting' do
      sign_in admin, scope: :user
      request = held_follow_request(preflight_state: :ready)

      get :show, params: { id: request }

      expect(response.body).to include(I18n.t('admin.action_reviews.inconsistent_resource'))
      expect(response.body).not_to include(I18n.t('admin.action_reviews.approve_and_run'))
    end

    it 'lets staff approve, persists an escaped note, and keeps browser-local reviewed_at' do
      sign_in Fabricate(:user, moderator: true), scope: :user
      request = held_follow_request
      note = '<script>alert(1)</script>'

      post :approve, params: { id: request.id, decision_note: note }

      expect(response).to redirect_to(admin_action_review_path(request))
      expect(flash[:notice]).to eq I18n.t('admin.action_reviews.approved_msg')
      expect(request.reload.approved_state?).to be true
      expect(request.decision_note).to eq note
      expect(request.resource.reload.ready_preflight_state?).to be true
      expect(ModerationAction.count).to eq 0

      get :show, params: { id: request }
      expect(response.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
      expect(response.body).not_to include('<script>alert(1)</script>')
      expect(response.body).to include('time class="formatted"')
      expect(response.body).to include(request.reviewed_at.iso8601)
      expect(response.body).not_to include(I18n.t('admin.action_reviews.approve_and_run'))
    end

    it 'lets staff stop the import' do
      sign_in admin, scope: :user
      request = held_follow_request

      expect { post :reject, params: { id: request.id, decision_note: 'stop this import' } }.not_to change(ModerationAction, :count)

      expect(response).to redirect_to(admin_action_review_path(request))
      expect(request.reload.rejected_state?).to be true
      expect(request.resource.reload.stopped_preflight_state?).to be true
      expect(request.decision_note).to eq 'stop this import'
    end

    it 'forbids an ordinary user from approving or stopping' do
      sign_in Fabricate(:user), scope: :user
      request = held_follow_request

      post :approve, params: { id: request.id }
      expect(response).to have_http_status(:forbidden)

      post :reject, params: { id: request.id }
      expect(response).to have_http_status(:forbidden)
      expect(request.reload.pending_state?).to be true
      expect(request.resource.reload.review_required_preflight_state?).to be true
    end
  end

  describe 'invite creation detail' do
    let(:owner) { Fabricate(:user, admin: true) }

    def held_invite
      Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
        value: { 'invite_creation' => 'always' }
      )
      Rails.cache.clear
      InviteCreation::CreateService.new.call(
        user: owner,
        attributes: { max_uses: 10, expires_in: 86_400, autofollow: false, comment: 'secret-comment-text' }
      )
    end

    before { sign_in admin, scope: :user }

    after do
      Setting.where(var: 'action_review_policies').delete_all
      Rails.cache.clear
    end

    it 'shows the requested facts and approve/stop without the code' do
      created = held_invite

      get :show, params: { id: created.request }

      expect(response.body).to include(I18n.t('admin.action_reviews.invite_creation.title'))
      expect(response.body).to include(I18n.t('admin.action_reviews.invite_creation.waiting'))
      expect(response.body).to include('10')
      expect(response.body).to include(I18n.t('invites.expires_in.86400'))
      expect(response.body).to include(I18n.t('admin.action_reviews.invite_creation.yes'))
      expect(response.body).to include(I18n.t('admin.action_reviews.approve_and_run'))
      expect(response.body).to include(I18n.t('admin.action_reviews.stop'))
      expect(response.body).to include(I18n.t('admin.action_reviews.invite_stop_confirm'))
      expect(response.body).not_to include(created.invite.code)
      expect(response.body).not_to include('secret-comment-text')
    end

    it 'hides controls and the code after the invite is stopped' do
      created = held_invite
      ActionReview::DecisionService.new.call(
        request: created.request,
        decision: 'reject',
        reviewer_account: admin.account,
        decision_note: nil
      )

      get :show, params: { id: created.request }

      expect(response.body).to include(I18n.t('admin.action_reviews.invite_creation.stopped'))
      expect(response.body).not_to include(I18n.t('admin.action_reviews.approve_and_run'))
      expect(response.body).not_to include(created.invite.code)
    end

    it 'warns when the invite shell is missing' do
      created = held_invite
      created.invite.delete

      get :show, params: { id: created.request.reload }

      expect(response.body).to include(I18n.t('admin.action_reviews.inconsistent_invite'))
      expect(response.body).not_to include(I18n.t('admin.action_reviews.approve_and_run'))
    end
  end

  describe 'navigation for moderators' do
    it 'shows the queue but not policy settings' do
      sign_in Fabricate(:user, moderator: true), scope: :user

      get :index

      expect(response.body).to include(I18n.t('admin.action_reviews.title'))
      expect(response.body).not_to include(I18n.t('admin.action_review_settings.title'))
    end
  end
end
