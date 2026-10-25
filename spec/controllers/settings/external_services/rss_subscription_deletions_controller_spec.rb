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
      expect(body).to include('state' => 'completed', 'finished' => true, 'polling' => false, 'percent' => 100)
      expect(body['message']).to eq I18n.t('external_bridge.deletion.message.completed')

      deletion.update_columns(state: 'failed', last_error_code: 'queue_error', finished_at: nil)
      get :show, params: { id: deletion.id }, session: challenge
      body = JSON.parse(response.body)
      expect(body).to include('state' => 'failed', 'retryable' => true, 'polling' => false)
      expect(body['error']).to eq I18n.t('external_bridge.deletion.errors.queue_error')
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
      deletion.update_columns(state: 'failed')
      post :retry, params: { id: deletion.id }
      expect(deletion.reload).to be_failed

      other = share_account_user(user.account)
      theirs = accepted_deletion(owner: other)
      theirs.update_columns(state: 'failed')
      post :retry, params: { id: theirs.id }, session: challenge
      expect(theirs.reload).to be_failed
      expect(flash[:alert]).to eq I18n.t('external_bridge.errors.not_found')
    end
  end
end

# rubocop:enable Metrics/BlockLength
