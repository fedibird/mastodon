# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Statuses::EmojiReactionsController, type: :controller do
  render_views

  let(:user) { Fabricate(:user) }
  let(:domain) { 'http-policy.example' }
  let(:author) do
    Fabricate(
      :account,
      username: 'remoteauthor',
      domain: domain,
      protocol: :activitypub,
      inbox_url: "https://#{domain}/inbox",
      uri: "https://#{domain}/users/remoteauthor"
    )
  end
  let(:status) { Fabricate(:status, account: author, uri: "https://#{domain}/status/1") }
  let(:enforced) do
    {
      'EMOJI_REACTION_CANONICAL_WRITES' => 'true',
      'EMOJI_REACTION_IDEMPOTENT_RETRY' => 'true',
      'EMOJI_REACTION_FALLBACK_POLICY_ENFORCE' => 'true',
    }
  end

  before do
    Node.create!(domain: domain, info: { 'emoji_reaction_type' => 'none', 'favourite' => true }, nodeinfo: { 'a' => 1 }, last_fetched_at: Time.now.utc)
    allow(controller).to receive(:doorkeeper_token) do
      Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:favourites')
    end
  end

  around { |example| ClimateControl.modify(enforced) { Sidekiq::Testing.fake! { example.run } } }

  def put_emoji(target, emoji = '👍', extra = {})
    put :update, params: { status_id: target.id, id: emoji }.merge(extra), format: :json
  end

  def body
    JSON.parse(response.body)
  end

  it 'returns the legacy 403 body for disable_reactions and still deletes' do
    user.settings['disable_reactions'] = true
    user.settings['emoji_reaction_fallback_policy'] = 'allow'
    put_emoji(status)

    expect(response).to have_http_status(403)
    expect(body).to eq('error' => 'This action is not allowed')
    expect(EmojiReaction.count).to eq 0

    user.settings['disable_reactions'] = false
    put_emoji(status)
    expect(response).to have_http_status(200)
    user.settings['emoji_reaction_fallback_policy'] = 'deny'
    user.settings['disable_reactions'] = true
    delete :destroy, params: { status_id: status.id, id: '👍' }
    expect(response).to have_http_status(200)
    expect(EmojiReaction.count).to eq 0
  end

  it 'uses 409 for ask and accepts the token from the query string or the JSON body' do
    user.settings['emoji_reaction_fallback_policy'] = 'ask'
    put_emoji(status)

    expect(response).to have_http_status(409)
    expect(body['error_code']).to eq 'fallback_confirmation_required'
    expect(body['error']).to eq 'Confirmation is required before this reaction is sent as a favourite to the server of the post'
    token = body.dig('details', 'confirmation_token')
    expect(EmojiReaction.count).to eq 0

    request.headers['Fallback-Confirmation'] = token
    put_emoji(status)
    expect(response).to have_http_status(409)
    expect(body['error_code']).to eq 'fallback_confirmation_required'

    put_emoji(status, '👍', fallback_confirmation: token)
    expect(response).to have_http_status(200)
    expect(body['id']).to eq status.id.to_s
    expect(JSON.parse(response.body)).not_to have_key('error_code')

    EmojiReaction.delete_all
    ActivityPub::DeliveryWorker.jobs.clear
    required = nil
    put_emoji(status)
    required = body.dig('details', 'confirmation_token')
    put :update, params: { status_id: status.id, id: '👍', fallback_confirmation: required }, as: :json
    expect(response).to have_http_status(200)
    expect(EmojiReaction.count).to eq 1
  end

  it 'accepts a token issued for the boost on the original status' do
    user.settings['emoji_reaction_fallback_policy'] = 'ask'
    booster = Fabricate(:account, username: 'booster')
    wrapper = Fabricate(:status, account: booster, reblog: status, text: '')
    put_emoji(wrapper)
    expect(response).to have_http_status(409)
    token = body.dig('details', 'confirmation_token')

    put_emoji(status, '👍', fallback_confirmation: token)
    expect(response).to have_http_status(200)
    expect(body['id']).to eq status.id.to_s
    expect(EmojiReaction.where(account: user.account, status_id: status.id).count).to eq 1
    expect(EmojiReaction.where(status_id: wrapper.id)).to be_empty
  end

  it 'keeps a status the viewer cannot see at 404 without a policy code' do
    user.settings['emoji_reaction_fallback_policy'] = 'deny'
    secret = "secret-body-#{SecureRandom.hex(4)}"
    hidden = Fabricate(:status, visibility: :private, text: secret)
    wrapper = Fabricate(:status, account: Fabricate(:account), reblog: hidden, text: '')
    put_emoji(wrapper)

    expect(response).to have_http_status(404), response.body
    expect(body['error_code']).to be_nil
    expect(body['error']).not_to eq 'This action is not allowed'
    expect(response.body).not_to include('fallback_denied')
    expect(response.body).not_to include(secret)
    expect(EmojiReaction.count).to eq 0
  end

  it 'returns 403 fallback_denied and does not deliver' do
    user.settings['emoji_reaction_fallback_policy'] = 'deny'
    put_emoji(status)

    expect(response).to have_http_status(403)
    expect(body['error']).to eq 'This action is not allowed'
    expect(body['error_code']).to eq 'fallback_denied'
    expect(body['details']).to eq('mechanism' => 'like_fallback')
    expect(EmojiReaction.count).to eq 0
    expect(ActivityPub::DeliveryWorker.jobs).to be_empty
  end
end
