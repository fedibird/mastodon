# frozen_string_literal: true

require 'rails_helper'

# The REST response and the enqueued delivery of the emoji reaction endpoints
# must be identical with the P1a shadow flag ON and OFF.
# rubocop:disable Metrics/BlockLength
RSpec.describe Api::V1::Statuses::EmojiReactionsController, type: :controller do
  render_views

  let(:user) { Fabricate(:user) }
  let(:domain) { 'remote.example' }
  let(:author) { Fabricate(:account, username: 'zorblax', domain: domain, protocol: :activitypub, inbox_url: "https://#{domain}/inbox", uri: "https://#{domain}/users/zorblax") }
  let(:status) { Fabricate(:status, account: author, uri: "https://#{domain}/users/zorblax/statuses/1") }
  let(:on_env) { { EMOJI_REACTION_RESOLVER_SHADOW: 'true', EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: '1' } }
  let(:off_env) { { EMOJI_REACTION_RESOLVER_SHADOW: nil, EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: nil } }

  before do
    Node.create!(domain: domain, info: { 'emoji_reaction_type' => 'custom', 'favourite' => true }, nodeinfo: { 'a' => 1 }, last_fetched_at: Time.now.utc)
    allow(controller).to receive(:doorkeeper_token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:favourites') }
    ActivityPub::DeliveryWorker.jobs.clear
  end

  around { |example| Sidekiq::Testing.fake! { example.run } }

  def run_cycle(env)
    ClimateControl.modify(env) do
      ActivityPub::DeliveryWorker.jobs.clear
      put :update, params: { status_id: status.id, id: '👍' }
      put_response = [response.status, stable_body]
      put_jobs = ActivityPub::DeliveryWorker.jobs.map { |job| normalize(job['args']) }

      ActivityPub::DeliveryWorker.jobs.clear
      delete :destroy, params: { status_id: status.id, id: '👍' }
      delete_response = [response.status, stable_body]
      delete_jobs = ActivityPub::DeliveryWorker.jobs.map { |job| normalize(job['args']) }

      { put: put_response, put_jobs: put_jobs, delete: delete_response, delete_jobs: delete_jobs }
    end
  end

  # The reaction cache refresh bumps the status updated_at on every run.
  def stable_body
    JSON.parse(response.body).except('updated_at')
  end

  def normalize(args)
    json, account_id, inbox_url = args
    [Oj.load(json).except('signature').to_json.gsub(%r{emoji_reactions/\d+}, 'emoji_reactions/N'), account_id, inbox_url]
  end

  it 'returns the same responses and enqueues the same deliveries with the flag ON as OFF' do
    off = run_cycle(off_env)
    on = run_cycle(on_env)

    expect(off[:put][0]).to eq 200
    expect(off[:put_jobs].size).to eq 1
    expect(off[:delete_jobs].size).to eq 1
    expect(on).to eq off
  end

  it 'records one create and one undo observation with the flag ON only' do
    run_cycle(off_env)
    expect(EmojiReactionCapability::ShadowReport.collect(hours: 1)).to be_empty

    run_cycle(on_env)
    summary = EmojiReactionCapability::ShadowReport.summarize(EmojiReactionCapability::ShadowReport.collect(hours: 1))

    expect(summary[:ops]['create']).to eq(total: 1, match: 1, diff: 0)
    expect(summary[:ops]['undo']).to eq(total: 1, match: 0, diff: 1)
  end

  it 'still answers when the shadow raises' do
    allow(EmojiReactionCapability::ShadowRecorder).to receive(:increment).and_raise(RuntimeError)

    ClimateControl.modify(on_env) do
      put :update, params: { status_id: status.id, id: '👍' }
      expect(response).to have_http_status(200)
      expect(ActivityPub::DeliveryWorker.jobs.size).to eq 1
    end
  end
end
# rubocop:enable Metrics/BlockLength
