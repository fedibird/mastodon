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

  describe 'GET #show' do
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
      expect(controller).not_to respond_to(:approve)
      expect(controller).not_to respond_to(:reject)
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

    it 'has no approve or reject routes' do
      request = fabricate_request

      %w(approve reject).each do |action|
        recognized = Rails.application.routes.recognize_path("/admin/action_reviews/#{request.id}/#{action}", method: :post)
        expect(recognized[:controller]).to eq 'application'
        expect(recognized[:action]).to eq 'raise_not_found'
      end
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
