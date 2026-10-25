# frozen_string_literal: true

require 'rails_helper'

# REST shape for P1b-1a. The body is always the status named in the URL.
# rubocop:disable Metrics/BlockLength
RSpec.describe Api::V1::Statuses::EmojiReactionsController, type: :controller do
  render_views

  let(:user) { Fabricate(:user) }
  let(:author_user) { Fabricate(:user) }
  let(:author) { author_user.account }
  let(:booster_user) { Fabricate(:user) }
  let(:booster) { booster_user.account }
  let(:on_flags) { { 'EMOJI_REACTION_CANONICAL_WRITES' => 'true', 'EMOJI_REACTION_IDEMPOTENT_RETRY' => 'true' } }
  let(:off_flags) { { 'EMOJI_REACTION_CANONICAL_WRITES' => nil, 'EMOJI_REACTION_IDEMPOTENT_RETRY' => nil } }

  before do
    allow(controller).to receive(:doorkeeper_token) do
      Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:favourites')
    end
  end

  around { |example| Sidekiq::Testing.fake! { example.run } }

  def with_flags(flags, &block)
    ClimateControl.modify(flags, &block)
  end

  def with_cap(value)
    previous = Setting.reaction_max_per_account
    Setting.reaction_max_per_account = value
    yield
  ensure
    Setting.reaction_max_per_account = previous
  end

  def put_emoji(status, emoji = '👍')
    put :update, params: { status_id: status.id, id: emoji }, format: :json
  end

  def delete_emoji(status, emoji = '👍')
    delete :destroy, params: { status_id: status.id, id: emoji }, format: :json
  end

  def body
    JSON.parse(response.body)
  end

  def reaction_count(status)
    EmojiReaction.where(account: user.account, status_id: status.id).count
  end

  describe 'routes' do
    it 'keeps PUT, DELETE, unreact, and emoji_unreaction' do
      expect(put: '/api/v1/statuses/7/emoji_reactions/like').to route_to(
        controller: 'api/v1/statuses/emoji_reactions', action: 'update', status_id: '7', id: 'like'
      )
      expect(delete: '/api/v1/statuses/7/emoji_reactions/like').to route_to(
        controller: 'api/v1/statuses/emoji_reactions', action: 'destroy', status_id: '7', id: 'like'
      )
      expect(post: '/api/v1/statuses/7/unreact/like').to route_to(
        controller: 'api/v1/statuses/emoji_reactions', action: 'destroy', status_id: '7', id: 'like'
      )
      expect(post: '/api/v1/statuses/7/react/like').to route_to(
        controller: 'api/v1/statuses/emoji_reactions', action: 'update', status_id: '7', id: 'like'
      )
      expect(post: '/api/v1/statuses/7/emoji_unreaction').to route_to(
        controller: 'api/v1/statuses/emoji_reactions', action: 'destroy', status_id: '7'
      )
    end
  end

  describe 'with both flags on' do
    let(:status) { Fabricate(:status, account: author, text: 'original body') }
    let(:wrapper) { Fabricate(:status, account: booster, reblog: status, text: '') }

    it 'accepts original then boost then original, one row, one distribution, URL status in the body' do
      with_flags(on_flags) do
        put_emoji(status)
        expect(response).to have_http_status(200)
        expect(body['id']).to eq status.id.to_s

        ActivityPub::CustomEmojiDistributionWorker.jobs.clear
        put_emoji(wrapper)
        expect(response).to have_http_status(200)
        expect(body['id']).to eq wrapper.id.to_s
        expect(body['reblog']['id']).to eq status.id.to_s
        expect(body.keys).to include('id', 'reblog', 'emoji_reactions', 'emoji_reactions_count', 'content')

        put_emoji(status)
        expect(response).to have_http_status(200)
        expect(body['id']).to eq status.id.to_s
      end

      expect(reaction_count(status)).to eq 1
      expect(reaction_count(wrapper)).to eq 0
      expect(ActivityPub::CustomEmojiDistributionWorker.jobs).to be_empty
      expect(Notification.where(activity_type: 'EmojiReaction').count).to eq 1
    end

    it 'accepts the opposite order the same way' do
      with_flags(on_flags) do
        put_emoji(wrapper)
        put_emoji(status)
        put_emoji(wrapper)
        expect(response).to have_http_status(200)
        expect(body['id']).to eq wrapper.id.to_s
      end

      expect(reaction_count(status)).to eq 1
      expect(ActivityPub::CustomEmojiDistributionWorker.jobs.size).to eq 1
    end

    it 'returns 200 for an existing emoji after the cap is reached' do
      with_flags(on_flags) do
        put_emoji(status)
        put_emoji(wrapper)
        expect(response).to have_http_status(200)
        put_emoji(status, '🎉')
        expect(response).to have_http_status(422)
      end

      expect(reaction_count(status)).to eq 1
    end

    it 'deletes one emoji or every emoji through the boost, and no-ops a missing emoji' do
      with_cap(2) do
      with_flags(on_flags) do
        put_emoji(wrapper, '👍')
        put_emoji(status, '🎉')
        delete_emoji(wrapper, '👍')
        expect(response).to have_http_status(200)
        expect(body['id']).to eq wrapper.id.to_s
        expect(EmojiReaction.where(account: user.account, status: status).pluck(:name)).to eq ['🎉']

        post :destroy, params: { status_id: wrapper.id, id: '👍' }, format: :json
        expect(response).to have_http_status(200)
        expect(EmojiReaction.where(account: user.account, status: status).pluck(:name)).to eq ['🎉']

        post :destroy, params: { status_id: wrapper.id }, format: :json
        expect(response).to have_http_status(200)
        expect(body['id']).to eq wrapper.id.to_s
        expect(reaction_count(status)).to eq 0
      end
      end
    end
  end

  describe 'with both flags off' do
    it 'still 422s a repeat through a boost once the original holds the row' do
      status = Fabricate(:status, account: author)
      wrapper = Fabricate(:status, account: booster, reblog: status, text: '')

      with_flags(off_flags) do
        put_emoji(status)
        expect(response).to have_http_status(200)
        put_emoji(wrapper)
        expect(response).to have_http_status(422)
      end

      expect(reaction_count(status)).to eq 1
      expect(reaction_count(wrapper)).to eq 0
    end
  end

  describe 'response and delivery parity' do
    let(:domain) { "remote-#{SecureRandom.hex(4)}.example" }
    let(:booster_domain) { "boost-#{SecureRandom.hex(4)}.example" }
    let(:remote_author) do
      Fabricate(:account, domain: domain, protocol: :activitypub, inbox_url: "https://#{domain}/users/a/inbox", uri: "https://#{domain}/users/a")
    end
    let(:remote_booster) do
      Fabricate(:account, domain: booster_domain, protocol: :activitypub, inbox_url: "https://#{booster_domain}/users/b/inbox", uri: "https://#{booster_domain}/users/b")
    end

    def normalized_jobs
      ActivityPub::DeliveryWorker.jobs.map do |job|
        json, account_id, inbox = job['args']
        payload = Oj.load(json).except('signature')
        payload['id'] = payload['id'].to_s.gsub(%r{emoji_reactions/\d+}, 'emoji_reactions/N')
        [payload, account_id, inbox]
      end
    end

    it 'keeps the same activity type, inbox, and REST keys for a new boost reaction' do
      Node.create!(domain: domain, info: { 'emoji_reaction_type' => 'unicode', 'favourite' => true }, nodeinfo: { 'a' => 1 }, last_fetched_at: Time.now.utc)
      Node.create!(domain: booster_domain, info: { 'emoji_reaction_type' => 'none', 'favourite' => 'none' }, nodeinfo: { 'a' => 1 }, last_fetched_at: Time.now.utc)
      status = Fabricate(:status, account: remote_author, text: 'remote original', uri: "https://#{domain}/statuses/1")
      wrapper = Fabricate(:status, account: remote_booster, reblog: status, text: '', uri: "https://#{booster_domain}/statuses/9")

      captured = {}
      [off_flags, on_flags].each do |flags|
        ActivityPub::DeliveryWorker.jobs.clear
        EmojiReaction.where(account: user.account).delete_all
        with_flags(flags) { put_emoji(wrapper) }
        expect(response).to have_http_status(200)
        captured[flags] = { keys: body.keys.sort, id: body['id'], reblog_id: body.dig('reblog', 'id'), jobs: normalized_jobs }
      end

      expect(captured[on_flags][:keys]).to eq captured[off_flags][:keys]
      expect(captured[on_flags][:id]).to eq wrapper.id.to_s
      expect(captured[off_flags][:id]).to eq wrapper.id.to_s
      expect(captured[on_flags][:reblog_id]).to eq status.id.to_s
      expect(captured[on_flags][:jobs]).to eq captured[off_flags][:jobs]
      expect(captured[on_flags][:jobs].map(&:last)).to eq ["https://#{domain}/users/a/inbox"]
      expect(captured[on_flags][:jobs].map { |payload, _, _| payload['type'] }).to eq ['EmojiReact']
      expect(captured[on_flags][:jobs].map { |payload, _, _| payload['object'] }).to eq [status.uri]
    end
  end

  describe 'show? is not widened' do
    let(:secret) { "secret-body-#{SecureRandom.hex(4)}" }

    def wrapper_for(status)
      Fabricate(:status, account: booster, reblog: status, text: '')
    end

    it 'refuses a boost of a status the viewer cannot show when canonical writes are on' do
      blocked_author = Fabricate(:account)
      blocked = Fabricate(:status, account: blocked_author, text: secret)
      blocked_author.block!(user.account)
      private_status = Fabricate(:status, visibility: :private, text: secret)
      limited = Fabricate(:status, visibility: :limited, text: secret)
      projection = Fabricate(:status, text: secret)
      projection.update_columns(external_projection: true)

      [blocked, private_status, limited, projection].each do |hidden|
        wrapper = wrapper_for(hidden)
        with_flags(on_flags) { put_emoji(wrapper) }
        expect(response).to have_http_status(404), "status #{hidden.id} visibility=#{hidden.visibility} http=#{response.status}"
        expect(response.body).not_to include(secret)
        expect(EmojiReaction.where(account: user.account, status_id: hidden.id)).not_to exist
      end
    end

    it 'does not start refusing those boosts while the flag is off' do
      blocked = Fabricate(:status, account: author, text: 'visible-enough')
      author.block!(user.account)
      wrapper = wrapper_for(blocked)

      with_flags(off_flags) { put_emoji(wrapper) }

      expect(response).to have_http_status(200)
      expect(EmojiReaction.where(account: user.account, status_id: blocked.id)).to exist
    end

    it 'still forbids a new reaction when the user disabled reactions, and still allows undo' do
      status = Fabricate(:status, account: author)
      user.settings['disable_reactions'] = true

      [off_flags, on_flags].each do |flags|
        EmojiReaction.where(account: user.account).delete_all
        EmojiReaction.create!(account: user.account, status: status, name: '👍')
        with_flags(flags) do
          put_emoji(status, '🎉')
          expect(response).to have_http_status(403)
          delete_emoji(status, '👍')
          expect(response).to have_http_status(200)
        end
        expect(EmojiReaction.where(account: user.account, status: status)).not_to exist
      end
    end
  end

  describe 'shadow observation' do
    let(:domain) { "shadow-#{SecureRandom.hex(4)}.example" }
    let(:remote_author) do
      Fabricate(:account, domain: domain, protocol: :activitypub, inbox_url: "https://#{domain}/inbox", uri: "https://#{domain}/users/z")
    end

    before do
      Node.create!(domain: domain, info: { 'emoji_reaction_type' => 'custom', 'favourite' => true }, nodeinfo: { 'a' => 1 }, last_fetched_at: Time.now.utc)
    end

    it 'records a create only when a new delivery happens' do
      status = Fabricate(:status, account: remote_author, uri: "https://#{domain}/statuses/1")
      env = on_flags.merge('EMOJI_REACTION_RESOLVER_SHADOW' => 'true', 'EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE' => '1')
      allow(EmojiReactionCapability::ShadowRecorder).to receive(:increment)

      with_flags(env) do
        put_emoji(status)
        put_emoji(status)
      end

      expect(EmojiReactionCapability::ShadowRecorder).to have_received(:increment).once
    end
  end
end
# rubocop:enable Metrics/BlockLength
