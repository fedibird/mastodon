# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require 'rails_helper'

RSpec.describe 'RSS subscription deletion API' do
  around do |example|
    Sidekiq::Testing.fake! { example.run }
  end

  let(:owner) { Fabricate(:user, account: Fabricate(:account, username: 'deletionowner')) }
  let(:roommate) { share_account_user(owner.account) }
  let(:stranger) { Fabricate(:user) }
  let(:bundle) { project_for(owner, body: 'Owner only article', url: 'https://feeds.example/SECRET_FEED_TOKEN/feed.xml') }
  let(:owner_headers) { auth_headers_for(owner) }
  let(:base) { '/api/v1/external_bridge/rss/subscription_deletions' }

  before do
    ExternalBridge::RSS::SubscriptionDeletionWorker.clear
    enable_external_bridge_rss!(owner)
    bundle
  end

  def accept!
    delete "/api/v1/external_bridge/rss/subscriptions/#{bundle[:subscription].id}", headers: owner_headers
    expect(response).to have_http_status(202)
    body_as_json
  end

  describe 'DELETE /api/v1/external_bridge/rss/subscriptions/:id' do
    it 'answers 202 with the job without waiting for the delete, and the same job again' do
      job = accept!

      expect(job[:id]).to be_present
      expect(job[:subscription_id]).to eq bundle[:subscription].id.to_s
      expect(job[:state]).to eq 'queued'
      expect(job[:preparing]).to be true
      expect(job[:total]).to be_nil
      expect(job[:remaining]).to be_nil
      expect(job[:percent]).to be_nil
      expect(job[:eta_seconds]).to be_nil
      expect(job[:url]).to eq "#{base}/#{job[:id]}"
      expect(Status.exists?(bundle[:status].id)).to be true
      expect(ExternalSubscription.find(bundle[:subscription].id).state).to eq 'deleting'

      again = accept!
      expect(again[:id]).to eq job[:id]
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1
    end

    it 'shows the deleting state in the subscription list and refuses a new subscription with 409' do
      accept!
      stub_request(:get, bundle[:source].canonical_key).to_return(status: 200, body: rss_document(rss_item(guid: 'x')))

      get '/api/v1/external_bridge/rss/subscriptions', headers: owner_headers
      expect(body_as_json.map { |row| row[:state] }).to eq ['deleting']

      post '/api/v1/external_bridge/rss/subscriptions', params: { url: bundle[:source].canonical_key }, headers: owner_headers
      expect(response).to have_http_status(409)
      expect(body_as_json[:error]).to eq 'subscription_deleting'

      post "/api/v1/external_bridge/rss/subscriptions/#{bundle[:subscription].id}/pause", headers: owner_headers
      expect(response).to have_http_status(409)

      get "/api/v1/external_bridge/rss/subscriptions/#{bundle[:subscription].id}/statuses", headers: owner_headers
      expect(response).to have_http_status(404)
    end

    it 'hides the subscription of another user, including a roommate, with 404' do
      delete "/api/v1/external_bridge/rss/subscriptions/#{bundle[:subscription].id}", headers: auth_headers_for(roommate)
      expect(response).to have_http_status(404)
      delete "/api/v1/external_bridge/rss/subscriptions/#{bundle[:subscription].id}", headers: auth_headers_for(stranger)
      expect(response).to have_http_status(404)
      expect(ExternalSubscription.find(bundle[:subscription].id).state).to eq 'active'
    end
  end

  describe 'GET progress' do
    it 'shows the owner the counters and nothing that identifies the feed' do
      job = accept!
      ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(job[:id].to_i)

      get "#{base}/#{job[:id]}", headers: owner_headers

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(state: 'completed', total: 1, deleted: 1, remaining: 0, percent: 100, preparing: false, retryable: false)
      expect(body_as_json[:finished_at]).to be_present
      expect(response.body).not_to include('SECRET_FEED_TOKEN')
      expect(response.body).not_to include('Owner only article')
      expect(response.body).not_to include('feeds.example')

      get base, headers: owner_headers
      expect(body_as_json.map { |row| row[:id] }).to eq [job[:id]]
    end

    it 'answers 404 for the roommate, another user, a missing id, and 401 for no token' do
      job = accept!

      [auth_headers_for(roommate), auth_headers_for(stranger)].each do |headers|
        get "#{base}/#{job[:id]}", headers: headers
        expect(response).to have_http_status(404)
      end
      get "#{base}/0", headers: owner_headers
      expect(response).to have_http_status(404)
      get "#{base}/#{job[:id]}"
      expect(response).to have_http_status(401)

      get base, headers: auth_headers_for(roommate)
      expect(body_as_json).to eq []
    end

    it 'needs the read scope' do
      job = accept!

      get "#{base}/#{job[:id]}", headers: auth_headers_for(owner, 'write:statuses')
      expect(response).to have_http_status(403)
      get "#{base}/#{job[:id]}", headers: auth_headers_for(owner, 'read:statuses')
      expect(response).to have_http_status(200)
    end

    it 'reports a failed job with a fixed code and lets the owner retry it once' do
      job = accept!
      deletion = ExternalSubscriptionDeletion.find(job[:id])
      deletion.update_columns(state: 'failed', last_error_code: 'database_error', attempt_count: 5, next_run_at: nil, total_count: 10, deleted_count: 4)
      ExternalBridge::RSS::SubscriptionDeletionWorker.clear

      get "#{base}/#{job[:id]}", headers: owner_headers
      expect(body_as_json).to include(state: 'failed', retryable: true, last_error_code: 'database_error', remaining: 6, percent: 40)

      post "#{base}/#{job[:id]}/retry", headers: auth_headers_for(roommate)
      expect(response).to have_http_status(404)
      post "#{base}/#{job[:id]}/retry", headers: auth_headers_for(owner, 'read:statuses')
      expect(response).to have_http_status(403)

      post "#{base}/#{job[:id]}/retry", headers: owner_headers
      expect(response).to have_http_status(202)
      expect(body_as_json[:state]).to eq 'queued'
      post "#{base}/#{job[:id]}/retry", headers: owner_headers
      expect(response).to have_http_status(202)
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1
    end
  end
end

# rubocop:enable Metrics/BlockLength
