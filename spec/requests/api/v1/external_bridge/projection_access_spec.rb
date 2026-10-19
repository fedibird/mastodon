# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Private RSS projection access' do
  let(:owner) { Fabricate(:user, account: Fabricate(:account, username: 'rssowner')) }
  let(:roommate) { share_account_user(owner.account) }
  let(:stranger) { Fabricate(:user) }
  let(:bundle) { project_for(owner, body: 'Owner only article') }
  let(:status) { bundle[:status] }
  let(:owner_headers) { auth_headers_for(owner) }
  let(:roommate_headers) { auth_headers_for(roommate) }
  let(:stranger_headers) { auth_headers_for(stranger) }

  before { bundle }

  describe 'GET /api/v1/statuses/:id' do
    it 'returns the owner extension and hides the id from the other user of the account' do
      get "/api/v1/statuses/#{status.id}", headers: owner_headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:visibility_ex]).to eq 'personal'
      expect(body_as_json[:fedibird_external]).to include(protocol: 'rss', canonical_url: 'https://example.com/posts/1', interaction: 'local_only')
      expect(body_as_json[:content]).to include('Owner only article')

      get "/api/v1/statuses/#{status.id}", headers: roommate_headers
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('Owner only article')

      get "/api/v1/statuses/#{status.id}", headers: stranger_headers
      expect(response).to have_http_status(404)

      get "/api/v1/statuses/#{status.id}"
      expect(response).to have_http_status(404)
    end

    it 'omits the id from personal, account, context, and batch reads for the other user' do
      ordinary = Fabricate(:status, account: owner.account, visibility: :personal, text: 'Ordinary personal')
      mentioned = Fabricate(:user)
      Mention.create!(account: mentioned.account, status: status)

      owner_ids = PersonalFeed.new(owner.account, viewer_user_id: owner.id).get(20).map(&:id)
      roommate_ids = PersonalFeed.new(owner.account, viewer_user_id: roommate.id).get(20).map(&:id)
      expect(owner_ids).to include(status.id, ordinary.id)
      expect(roommate_ids).to include(ordinary.id)
      expect(roommate_ids).not_to include(status.id)

      nil_ids = Status.permitted_statuses_from_ids([status.id, ordinary.id], owner.account_id, viewer_user_id: nil).map(&:id)
      expect(nil_ids).to eq [ordinary.id]
      roommate_batch = Status.permitted_statuses_from_ids([status.id], owner.account_id, viewer_user_id: roommate.id)
      expect(roommate_batch).to be_empty

      get "/api/v1/timelines/personal", headers: roommate_headers
      expect(response.body).not_to include(status.id.to_s)

      get "/api/v1/accounts/#{owner.account_id}/statuses", headers: owner_headers
      expect(response.body).not_to include('Owner only article')

      parent = Fabricate(:status, account: stranger.account, text: 'Unrelated')
      get "/api/v1/statuses/#{parent.id}/context", headers: stranger_headers
      expect(response.body).not_to include(status.id.to_s)

      ExternalBridge::Viewer.user_id = mentioned.id
      expect(StatusPolicy.new(mentioned.account, status).show?).to be false
    end

    it 'uses one marker lookup for a page of ids' do
      ids = Array.new(5) { Fabricate(:status, account: owner.account).id } + [status.id]
      queries = []
      callback = lambda do |*, payload|
        queries << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:sql].include?('SCHEMA')
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        Status.permitted_statuses_from_ids(ids, stranger.account_id, viewer_user_id: stranger.id)
      end

      marker_queries = queries.count { |sql| sql.include?('external_status_projections') }
      expect(marker_queries).to be <= 2
    end
  end

  describe 'lists and local actions' do
    it 'hides the projection from the other user favourite, bookmark, and reaction lists' do
      Favourite.create!(account: owner.account, status: status)
      Bookmark.create!(account: owner.account, status: status)
      EmojiReaction.create!(account: owner.account, status: status, name: '👍')

      get '/api/v1/favourites?compact=true', headers: roommate_headers
      expect(response).to have_http_status(200)
      expect(response.body).not_to include(status.id.to_s)

      get '/api/v1/bookmarks', headers: roommate_headers
      expect(response.body).not_to include(status.id.to_s)

      get '/api/v1/emoji_reactions?compact=true', headers: roommate_headers
      expect(response.body).not_to include(status.id.to_s)

      get '/api/v1/favourites', headers: owner_headers
      expect(response.body).to include(status.id.to_s)
    end

    it 'lets the owner favourite and bookmark without delivery or a trend register' do
      expect(ActivityPub::DeliveryWorker).not_to receive(:perform_async)
      expect(Trends.statuses).not_to receive(:register)

      post "/api/v1/statuses/#{status.id}/favourite", headers: owner_headers
      expect(response).to have_http_status(200)
      expect(Favourite.where(account: owner.account, status: status)).to exist

      post "/api/v1/statuses/#{status.id}/bookmark", headers: owner_headers
      expect(response).to have_http_status(200)
      expect(Bookmark.where(account: owner.account, status: status)).to exist

      post "/api/v1/statuses/#{status.id}/unfavourite", headers: owner_headers
      expect(response).to have_http_status(200)
      expect(Favourite.where(account: owner.account, status: status)).not_to exist

      post "/api/v1/statuses/#{status.id}/unbookmark", headers: owner_headers
      expect(Bookmark.where(account: owner.account, status: status)).not_to exist
    end

    it 'does not let the other user of the account favourite, unfavourite, or unbookmark' do
      Favourite.create!(account: owner.account, status: status)
      Bookmark.create!(account: owner.account, status: status)

      post "/api/v1/statuses/#{status.id}/favourite", headers: roommate_headers
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('Owner only article')

      expect(UnfavouriteWorker).not_to receive(:perform_async)
      post "/api/v1/statuses/#{status.id}/unfavourite", headers: roommate_headers
      expect(response).to have_http_status(404)
      expect(Favourite.where(account: owner.account, status: status)).to exist

      post "/api/v1/statuses/#{status.id}/unbookmark", headers: roommate_headers
      expect(response).to have_http_status(404)
      expect(Bookmark.where(account: owner.account, status: status)).to exist
    end

    it 'refuses reply, boost, quote, emoji reaction, edit, and pin' do
      expect do
        PostStatusService.new.call(owner.account, text: 'reply', thread: status, visibility: 'public')
      end.to raise_error(Mastodon::ValidationError)
      expect do
        ReblogService.new.call(owner.account, status)
      end.to raise_error(Mastodon::ValidationError)
      expect do
        EmojiReactionService.new.call(owner.account, status, 'star')
      end.to raise_error(Mastodon::ValidationError)
      expect do
        UpdateStatusService.new.call(status, owner.account_id, text: 'changed')
      end.to raise_error(Mastodon::ValidationError)
      expect do
        PinService.new.call(owner.account, status)
      end.to raise_error(Mastodon::ValidationError)

      post "/api/v1/statuses/#{status.id}/emoji_reactions/%F0%9F%91%8D", headers: roommate_headers
      expect(response).to have_http_status(404)
      expect(EmojiReaction.where(status: status)).not_to exist
      expect(Status.where(in_reply_to_id: status.id)).not_to exist
      expect(Status.where(reblog_of_id: status.id)).not_to exist
    end
  end

  describe 'public surfaces' do
    before do
      allow(Webpacker.instance.manifest).to receive(:lookup).and_return('/packs-test/stub')
      allow(Webpacker.instance.manifest).to receive(:lookup!) do |_name, with_integrity: false, **|
        with_integrity ? ['/packs-test/stub', nil] : '/packs-test/stub'
      end
    end

    it 'returns not found for HTML, ActivityPub JSON, and oEmbed' do
      get "/@#{owner.account.username}/#{status.id}"
      expect(response).to have_http_status(404)
      expect(response.body).not_to include('Owner only article')

      get "/users/#{owner.account.username}/statuses/#{status.id}", headers: { 'Accept' => 'application/activity+json' }
      expect(response).to have_http_status(404)

      get '/api/oembed', params: { url: short_account_status_url(owner.account, status) }
      expect(response).to have_http_status(404)

      sign_in owner
      get "/@#{owner.account.username}/#{status.id}"
      expect(response).to have_http_status(200)
      expect(response.body).to include('Owner only article')

      get "/@#{owner.account.username}/#{status.id}", headers: { 'Accept' => 'application/activity+json' }
      expect(response).to have_http_status(404)
    end

    it 'keeps the projection out of the outbox, profile RSS, and a planted home feed' do
      Fabricate(:status, account: owner.account, text: 'Public hello', visibility: :public)
      redis.zadd(FeedManager.instance.key(:home, stranger.account_id), status.id, status.id)

      get "/users/#{owner.account.username}/outbox?page=true", headers: { 'Accept' => 'application/activity+json' }
      expect(response.body).not_to include('Owner only article')
      expect(response.body).to include('Public hello')

      profile_ids = owner.account.statuses.where(visibility: [:public, :unlisted]).without_unreleased_pages.where(Arel.sql(ExternalBridge::ProjectionPrivacy::NOT_PROJECTION_SQL)).pluck(:id)
      expect(profile_ids).not_to include(status.id)

      hydrated = Feed.new(:home, stranger.account_id).get(20)
      expect(hydrated.map(&:id)).not_to include(status.id)
    end

    it 'does not include the projection in a backup id list or an admin trend approval' do
      backup_ids = owner.account.statuses.without_unreleased_pages.where(Arel.sql(ExternalBridge::ProjectionPrivacy::NOT_PROJECTION_SQL)).pluck(:id)
      expect(backup_ids).not_to include(status.id)

      role = UserRole.create!(name: "Bridge taxonomist #{SecureRandom.hex(3)}", position: UserRole.maximum(:position).to_i + 1, permissions_as_keys: ['manage_taxonomies'])
      taxonomist = user_with_role(role)
      headers = auth_headers_for(taxonomist, 'admin:write admin:read')
      post "/api/v1/admin/trends/statuses/#{status.id}/approve", headers: headers

      expect(response).to have_http_status(404)
      expect(status.reload.trendable).not_to be true
    end
  end

  describe 'owner subscription API' do
    let(:feed_url) { 'https://feeds.example/owner.xml' }

    before { enable_external_bridge_rss! }

    it 'subscribes, lists items, and unsubscribes without showing another user the membership' do
      stub_request(:get, feed_url).to_return(status: 200, body: rss_document(rss_item(guid: 'owner-guid', body: 'From the feed')))

      post '/api/v1/external_bridge/rss/subscriptions', params: { url: feed_url }, headers: owner_headers
      expect(response).to have_http_status(201)
      subscription_id = body_as_json[:id]

      get '/api/v1/external_bridge/rss/subscriptions', headers: roommate_headers
      expect(body_as_json).to eq []

      get "/api/v1/external_bridge/rss/subscriptions/#{subscription_id}/statuses", headers: owner_headers
      expect(response).to have_http_status(200)
      expect(body_as_json.first[:id]).to be_present

      get "/api/v1/external_bridge/rss/subscriptions/#{subscription_id}/statuses", headers: roommate_headers
      expect(response).to have_http_status(404)

      delete "/api/v1/external_bridge/rss/subscriptions/#{subscription_id}", headers: owner_headers
      expect(response).to have_http_status(200)
      expect(ExternalSubscription.exists?(subscription_id)).to be false
      expect(ExternalStatusProjection.where(external_subscription_id: subscription_id)).to be_empty
      expect(ExternalSubscription.exists?(bundle[:subscription].id)).to be true
      expect(ExternalSource.where(canonical_key: feed_url)).to exist
    end

    it 'has no generic external service provider route' do
      route = Rails.application.routes.routes.find { |entry| entry.path.spec.to_s.include?('/settings/external_services/:provider') }
      expect(route).to be_nil
    end
  end

  describe 'ordinary personal posts' do
    it 'still stores a uri and stays visible to the account' do
      ordinary = PostStatusService.new.call(owner.account, text: 'My personal note', visibility: 'personal')

      expect(ordinary.reload.external_projection).not_to be true
      expect(ordinary.uri).to be_present
      expect(PersonalFeed.new(owner.account, viewer_user_id: owner.id).get(20).map(&:id)).to include(ordinary.id)
      expect(ExternalBridge::ProjectionPrivacy.private_status?(ordinary)).to be false
    end
  end
end
