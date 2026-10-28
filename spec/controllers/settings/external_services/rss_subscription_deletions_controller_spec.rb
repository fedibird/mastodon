# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require 'rails_helper'

describe Settings::ExternalServices::RSSSubscriptionDeletionsController do
  render_views

  around do |example|
    Sidekiq::Testing.fake! { example.run }
  end

  let(:user) { Fabricate(:user, password: '123456789') }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }

  before do
    sign_in user, scope: :user
    stub_webpacker_manifest
    enable_external_bridge_rss!(user)
    ExternalBridge::RSS::SubscriptionDeletionWorker.clear
  end

  def accepted_deletion(owner: user)
    world = project_for(owner, body: 'Hidden imported body')
    world[:source].update!(title: 'Deleting <b>feed</b>')
    ExternalBridge::RSS::Subscribe.new.unsubscribe!(user: owner, subscription_id: world[:subscription].id)
  end

  describe 'GET show (progress poll)' do
    it 'returns the owner state as JSON with localized text and no feed address' do
      deletion = accepted_deletion
      deletion.update_columns(state: 'running', total_count: 200, deleted_count: 50, started_at: 30.seconds.ago, last_progress_at: Time.current)

      get :show, params: { id: deletion.id }, session: challenge

      expect(response).to have_http_status(200)
      body = JSON.parse(response.body)
      expect(body).to include(
        'id' => deletion.id.to_s, 'state' => 'running', 'percent' => 25, 'finished' => false, 'polling' => true, 'retryable' => false,
        'dismissable' => false, 'visible' => true, 'hide_after_ms' => nil,
        'state_label' => I18n.t('external_bridge.deletion.state.running'),
        'message' => I18n.t('external_bridge.deletion.message.running')
      )
      expect(body['detail']).to include('50').and include('200').and include('150')
      expect(body['detail']).to include(I18n.t('external_bridge.deletion.eta', duration: 'x').split('x').first)
      expect(response.body).not_to include('feeds.example')
      expect(response.body).not_to include('Hidden imported body')
    end

    it 'says it is preparing before the first count and calculating before a speed is known' do
      deletion = accepted_deletion

      get :show, params: { id: deletion.id }, session: challenge
      expect(JSON.parse(response.body)['detail']).to eq I18n.t('external_bridge.deletion.preparing')
      expect(JSON.parse(response.body)['percent']).to be_nil

      deletion.update_columns(state: 'running', total_count: 10, deleted_count: 0)
      get :show, params: { id: deletion.id }, session: challenge
      expect(JSON.parse(response.body)['detail']).to include(I18n.t('external_bridge.deletion.eta_calculating'))
    end

    it 'reports completion and a failed state with the retry offered' do
      deletion = accepted_deletion
      ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(deletion.id)

      get :show, params: { id: deletion.id }, session: challenge
      body = JSON.parse(response.body)
      expect(body).to include('state' => 'completed', 'finished' => true, 'polling' => false, 'percent' => 100, 'dismissable' => true, 'visible' => true)
      expect(body['hide_after_ms']).to be_within(10_000).of(24.hours.in_milliseconds)
      expect(body['message']).to eq I18n.t('external_bridge.deletion.message.completed')

      deletion.update_columns(state: 'failed', last_error_code: 'queue_error', finished_at: nil, next_run_at: nil)
      get :show, params: { id: deletion.id }, session: challenge
      body = JSON.parse(response.body)
      expect(body).to include('state' => 'failed', 'retryable' => true, 'polling' => false)
      expect(body['error']).to eq I18n.t('external_bridge.deletion.errors.queue_error')
    end

    it 'keeps polling and does not offer a manual retry while an automatic retry is scheduled' do
      deletion = accepted_deletion
      deletion.update_columns(state: 'failed', last_error_code: 'database_error', attempt_count: 1, next_run_at: 2.minutes.from_now, total_count: 100, deleted_count: 40)

      get :show, params: { id: deletion.id }, session: challenge

      body = JSON.parse(response.body)
      expect(body).to include('state' => 'failed', 'retrying' => true, 'polling' => true, 'retryable' => false, 'finished' => false)
      expect(body['state_label']).to eq I18n.t('external_bridge.deletion.state.retrying')
      expect(body['message']).to eq I18n.t('external_bridge.deletion.message.retrying')
      expect(body['badge']).to eq 'warning'
      expect(body['detail']).to include('40').and include('60')
      expect(body['percent']).to eq 40
    end

    it 'stops polling and offers the manual retry only when the attempts are used up' do
      deletion = accepted_deletion
      deletion.update_columns(state: 'failed', last_error_code: 'database_error', attempt_count: 5, next_run_at: nil, total_count: 100, deleted_count: 40)

      get :show, params: { id: deletion.id }, session: challenge

      body = JSON.parse(response.body)
      expect(body).to include('state' => 'failed', 'retrying' => false, 'polling' => false, 'retryable' => true)
      expect(body['message']).to eq I18n.t('external_bridge.deletion.message.failed')
      expect(body['badge']).to eq 'unavailable'
    end

    it 'answers 404 for another user, a roommate, and a missing id' do
      other = share_account_user(user.account)
      theirs = accepted_deletion(owner: other)

      get :show, params: { id: theirs.id }, session: challenge
      expect(response).to have_http_status(404)
      get :show, params: { id: 0 }, session: challenge
      expect(response).to have_http_status(404)
    end

    it 'requires a signed-in user' do
      deletion = accepted_deletion
      sign_out :user

      get :show, params: { id: deletion.id }

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'POST retry' do
    it 'requeues only a failed job of the owner' do
      deletion = accepted_deletion
      deletion.update_columns(state: 'failed', last_error_code: 'database_error', attempt_count: 5, next_run_at: nil)
      ExternalBridge::RSS::SubscriptionDeletionWorker.clear

      post :retry, params: { id: deletion.id }, session: challenge

      expect(response).to redirect_to(settings_external_services_rss_path)
      expect(deletion.reload).to be_queued
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1
    end

    it 'does nothing without a fresh challenge and hides another user' do
      deletion = accepted_deletion
      deletion.update_columns(state: 'failed', next_run_at: nil)
      post :retry, params: { id: deletion.id }
      expect(deletion.reload).to be_failed

      other = share_account_user(user.account)
      theirs = accepted_deletion(owner: other)
      theirs.update_columns(state: 'failed', next_run_at: nil)
      post :retry, params: { id: theirs.id }, session: challenge
      expect(theirs.reload).to be_failed
      expect(flash[:alert]).to eq I18n.t('external_bridge.errors.not_found')
    end
  end

  describe 'POST dismiss' do
    it 'hides a completed card and leaves the progress row in place' do
      deletion = accepted_deletion
      ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(deletion.id)
      deletion.reload
      notice_at = deletion.control_enqueued_at
      effect = ExternalSubscriptionDeletionEffect.create!(external_subscription_deletion: deletion, status_id: deletion.id)

      post :dismiss, params: { id: deletion.id }

      expect(response).to redirect_to(settings_external_services_rss_path)
      expect(response).to have_http_status(:see_other)
      deletion.reload
      expect(deletion).to be_completed
      expect(deletion.dismissed_at).to be_within(2.seconds).of(Time.current)
      expect(deletion.control_enqueued_at).to eq notice_at
      expect(ExternalSubscriptionDeletionEffect.exists?(effect.id)).to be true
      stamp = deletion.dismissed_at

      post :dismiss, params: { id: deletion.id }
      expect(response).to have_http_status(:see_other)
      expect(deletion.reload.dismissed_at).to eq stamp

      get :show, params: { id: deletion.id }, session: challenge
      body = JSON.parse(response.body)
      expect(body).to include('visible' => false, 'dismissable' => false)
      expect(ExternalSubscriptionDeletion.exists?(deletion.id)).to be true
    end

    it 'rejects an unfinished card with 409 and does not require a fresh challenge' do
      deletion = accepted_deletion
      %w(queued running).each do |state|
        deletion.update_columns(state: state, dismissed_at: nil, finished_at: nil)
        post :dismiss, params: { id: deletion.id }
        expect(response).to have_http_status(:conflict)
        expect(deletion.reload.state).to eq state
        expect(deletion.dismissed_at).to be_nil
      end

      deletion.update_columns(state: 'failed', last_error_code: 'database_error', next_run_at: 2.minutes.from_now, finished_at: 2.days.ago)
      post :dismiss, params: { id: deletion.id }
      expect(response).to have_http_status(:conflict)
      expect(deletion.reload).to be_failed
      expect(deletion.dismissed_at).to be_nil

      deletion.update_columns(next_run_at: nil)
      post :dismiss, params: { id: deletion.id }
      expect(response).to have_http_status(:conflict)
      expect(deletion.reload.dismissed_at).to be_nil
      expect(deletion).to be_failed
    end

    it 'answers 404 for another user, a roommate, a missing id, and redirects an anonymous post' do
      deletion = accepted_deletion
      deletion.update_columns(state: 'completed', finished_at: Time.current)
      other = share_account_user(user.account)
      theirs = accepted_deletion(owner: other)
      theirs.update_columns(state: 'completed', finished_at: Time.current, control_enqueued_at: Time.current)

      post :dismiss, params: { id: theirs.id }, session: challenge
      expect(response).to have_http_status(:not_found)
      expect(response.body).to be_empty
      expect(theirs.reload.dismissed_at).to be_nil

      post :dismiss, params: { id: 0 }, session: challenge
      expect(response).to have_http_status(:not_found)
      post :dismiss, params: { id: 'nope' }, session: challenge
      expect(response).to have_http_status(:not_found)

      sign_out :user
      post :dismiss, params: { id: deletion.id }
      expect(response).to redirect_to(new_user_session_path)
      expect(deletion.reload.dismissed_at).to be_nil
    end

    it 'does not close a card when the CSRF token is missing' do
      deletion = accepted_deletion
      deletion.update_columns(state: 'completed', finished_at: Time.current, control_enqueued_at: Time.current)
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true

      post :dismiss, params: { id: deletion.id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(deletion.reload.dismissed_at).to be_nil
      expect(deletion.control_enqueued_at).to be_present
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end
  end
end

# rubocop:enable Metrics/BlockLength
