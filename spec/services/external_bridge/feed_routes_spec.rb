# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::FeedRoutes::Update do
  def save_routes(user, subscription, home:, list_ids:, revision: nil)
    described_class.new.call(
      user: user,
      subscription_id: subscription.id,
      home: home,
      list_ids: list_ids,
      expected_revision: revision.nil? ? subscription.reload.feed_routes_revision : revision
    )
  end

  def expect_unique_rejection(sql)
    ActiveRecord::Base.connection.execute(<<~SQL)
      DO $do$
      BEGIN
        #{sql};
        RAISE EXCEPTION 'statement succeeded';
      EXCEPTION
        WHEN unique_violation THEN
          NULL;
      END
      $do$;
    SQL
  end

  def routes_for(subscription)
    ExternalFeedRoute.where(external_subscription_id: subscription.id).order(:id).pluck(:destination, :list_id)
  end

  after do
    Setting.external_bridge_feeds = false
    Setting.external_bridge_feeds_testers = ''
    Setting.external_bridge_rss = false
    Setting.external_bridge_rss_testers = ''
  end

  let(:user) { Fabricate(:user) }
  let(:bundle) { external_project_for(user, body: 'Routed article') }
  let(:subscription) { bundle[:subscription] }

  before { enable_external_bridge_feeds!(user) }

  describe 'replacing one subscription route set' do
    it 'starts empty and does not invent a home route' do
      expect(routes_for(subscription)).to eq []
      expect(subscription.feed_routes_revision).to eq 0
    end

    it 'saves home only, list only, several lists, and both' do
      first = Fabricate(:list, account: user.account, title: 'Morning')
      second = Fabricate(:list, account: user.account, title: 'Evening')

      save_routes(user, subscription, home: true, list_ids: [])
      expect(routes_for(subscription)).to eq [['home', nil]]
      expect(subscription.reload.feed_routes_revision).to eq 1

      save_routes(user, subscription, home: false, list_ids: [second.id, first.id, first.id])
      expect(routes_for(subscription)).to eq [['list', first.id], ['list', second.id]]
      expect(subscription.reload.feed_routes_revision).to eq 2

      save_routes(user, subscription, home: true, list_ids: [first.id])
      expect(routes_for(subscription)).to contain_exactly(['home', nil], ['list', first.id])
      expect(subscription.reload.feed_routes_revision).to eq 3
    end

    it 'clears every destination without deleting the status, favourite, or bookmark' do
      list = Fabricate(:list, account: user.account)
      save_routes(user, subscription, home: true, list_ids: [list.id])
      FavouriteService.new.call(user.account, bundle[:status], viewer_user: user)
      user.account.bookmarks.find_or_create_by!(status: bundle[:status])

      save_routes(user, subscription, home: false, list_ids: [])

      expect(routes_for(subscription)).to eq []
      expect(Status.exists?(bundle[:status].id)).to be true
      expect(Favourite.where(account: user.account, status: bundle[:status])).to exist
      expect(Bookmark.where(account: user.account, status: bundle[:status])).to exist
      expect(ExternalStatusProjection.exists?(bundle[:marker].id)).to be true
    end

    it 'does not move the revision or updated_at when the set is unchanged' do
      save_routes(user, subscription, home: true, list_ids: [])
      subscription.update_columns(updated_at: 2.days.ago)
      revision = subscription.reload.feed_routes_revision
      updated_at = subscription.updated_at

      save_routes(user, subscription, home: true, list_ids: [])

      subscription.reload
      expect(subscription.feed_routes_revision).to eq revision
      expect(subscription.updated_at).to be_within(1.second).of(updated_at)
    end

    it 'rejects a stale revision without writing' do
      save_routes(user, subscription, home: true, list_ids: [])

      expect do
        save_routes(user, subscription, home: false, list_ids: [], revision: 0)
      end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'stale_feed_routes' }

      expect(routes_for(subscription)).to eq [['home', nil]]
      expect(subscription.reload.feed_routes_revision).to eq 1
    end

    it 'rolls back the whole set when one list is not owned' do
      owned = Fabricate(:list, account: user.account)
      foreign = Fabricate(:list)
      save_routes(user, subscription, home: true, list_ids: [])

      expect do
        save_routes(user, subscription, home: false, list_ids: [owned.id, foreign.id])
      end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_feed_route' }

      expect(routes_for(subscription)).to eq [['home', nil]]
      expect(subscription.reload.feed_routes_revision).to eq 1
    end

    it 'does not treat a missing or malformed parameter as clear-all' do
      save_routes(user, subscription, home: true, list_ids: [])

      [nil, 'maybe'].each do |home|
        expect do
          save_routes(user, subscription, home: home, list_ids: [], revision: subscription.reload.feed_routes_revision)
        end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_feed_route' }
      end

      expect do
        described_class.new.call(user: user, subscription_id: subscription.id, home: false, list_ids: nil, expected_revision: subscription.reload.feed_routes_revision)
      end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_feed_route' }

      expect do
        described_class.new.call(user: user, subscription_id: subscription.id, home: false, list_ids: [], expected_revision: 'nope')
      end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_feed_route' }

      expect(routes_for(subscription)).to eq [['home', nil]]
    end
  end

  describe 'ownership' do
    it 'refuses another user, including one who shares the account, and ignores a forged user id' do
      roommate = share_account_user(user.account)
      stranger = Fabricate(:user)
      list = Fabricate(:list, account: user.account)

      [roommate, stranger, nil].each do |actor|
        expect do
          described_class.new.call(user: actor, subscription_id: subscription.id, home: true, list_ids: [], expected_revision: 0)
        end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'not_found' }
      end

      roommate_bundle = external_project_for(roommate, body: 'Roommate article')
      save_routes(roommate, roommate_bundle[:subscription], home: false, list_ids: [list.id])

      expect(routes_for(subscription)).to eq []
      expect(routes_for(roommate_bundle[:subscription])).to eq [['list', list.id]]
      expect(ExternalFeedRoute.where(user_id: user.id)).to be_empty
    end

    it 'does not add a destination while delivery is off, and still allows a clear' do
      save_routes(user, subscription, home: true, list_ids: [])
      Setting.external_bridge_feeds = false

      expect do
        save_routes(user, subscription, home: true, list_ids: [Fabricate(:list, account: user.account).id])
      end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'feed_routes_disabled' }

      save_routes(user, subscription, home: false, list_ids: [])
      expect(routes_for(subscription)).to eq []

      expect do
        save_routes(user, subscription, home: true, list_ids: [])
      end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'feed_routes_disabled' }
    end

    it 'rejects a route that points at another user subscription, a home row with a list, or a second home' do
      other = external_project_for(Fabricate(:user))
      list = Fabricate(:list, account: user.account)
      save_routes(user, subscription, home: true, list_ids: [])

      expect_database_rejection(<<~SQL)
        INSERT INTO external_feed_routes (user_id, external_subscription_id, destination, created_at, updated_at)
        VALUES (#{user.id}, #{other[:subscription].id}, 'home', NOW(), NOW())
      SQL
      expect_database_rejection(<<~SQL)
        INSERT INTO external_feed_routes (user_id, external_subscription_id, destination, list_id, created_at, updated_at)
        VALUES (#{user.id}, #{subscription.id}, 'home', #{list.id}, NOW(), NOW())
      SQL
      expect_unique_rejection(<<~SQL)
        INSERT INTO external_feed_routes (user_id, external_subscription_id, destination, created_at, updated_at)
        VALUES (#{user.id}, #{subscription.id}, 'home', NOW(), NOW())
      SQL
      expect(routes_for(subscription)).to eq [['home', nil]]
    end

    it 'rejects a list whose account changes while a route points at it' do
      list = Fabricate(:list, account: user.account)
      save_routes(user, subscription, home: false, list_ids: [list.id])
      other_account = Fabricate(:account)

      expect_database_rejection(<<~SQL)
        UPDATE lists SET account_id = #{other_account.id} WHERE id = #{list.id}
      SQL

      expect(list.reload.account_id).to eq user.account_id
      expect(routes_for(subscription)).to eq [['list', list.id]]
    end

    it 'deletes only the route when the list is deleted' do
      list = Fabricate(:list, account: user.account)
      other = Fabricate(:list, account: user.account)
      save_routes(user, subscription, home: true, list_ids: [list.id, other.id])

      list.destroy!

      expect(routes_for(subscription)).to contain_exactly(['home', nil], ['list', other.id])
      expect(ExternalSubscription.exists?(subscription.id)).to be true
      expect(Status.exists?(bundle[:status].id)).to be true
    end
  end

  describe 'subscribe, resume, and unsubscribe' do
    let(:feed_url) { 'https://feeds.example/routes.xml' }

    before do
      enable_external_bridge_rss!(user)
      stub_request(:get, feed_url).to_return(status: 200, body: rss_document(rss_item(guid: 'route-item')))
    end

    it 'does not create a route when a feed is subscribed or resumed' do
      subscribed = ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
      expect(ExternalFeedRoute.where(external_subscription_id: subscribed.id)).to be_empty
      expect(subscribed.feed_routes_revision).to eq 0

      list = Fabricate(:list, account: user.account)
      save_routes(user, subscribed, home: true, list_ids: [list.id])
      revision = subscribed.reload.feed_routes_revision
      subscribed.update!(state: 'paused')
      refresher = instance_double(ExternalBridge::RSS::RefreshSource, call: true)
      allow(ExternalBridge::RSS::RefreshSource).to receive(:new).and_return(refresher)

      ExternalBridge::RSS::Subscribe.new.resume!(user: user, subscription_id: subscribed.id)

      expect(routes_for(subscribed)).to contain_exactly(['home', nil], ['list', list.id])
      expect(subscribed.reload.feed_routes_revision).to eq revision
      expect(subscribed.state).to eq 'active'
    end

    it 'removes routes with the subscription and leaves the public source' do
      subscribed = ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
      save_routes(user, subscribed, home: true, list_ids: [])
      source_id = subscribed.external_source_id
      status_ids = ExternalStatusProjection.where(external_subscription_id: subscribed.id).pluck(:status_id)

      ExternalBridge::RSS::Subscribe.new.unsubscribe!(user: user, subscription_id: subscribed.id)

      expect(ExternalSubscription.where(id: subscribed.id)).to be_empty
      expect(ExternalFeedRoute.where(external_subscription_id: subscribed.id)).to be_empty
      expect(Status.where(id: status_ids)).to be_empty
      expect(ExternalSource.exists?(source_id)).to be true
    end
  end

  describe 'a writer that loses the subscription lock' do
    self.use_transactional_tests = false

    after do
      Setting.external_bridge_feeds = false
      Setting.external_bridge_feeds_testers = ''
      Setting.external_bridge_rss = false
      Setting.external_bridge_rss_testers = ''
      if defined?(@race_user) && @race_user&.persisted?
        ExternalBridge::ProjectionPurge.purge_user!(@race_user)
        ExternalFeedRoute.where(user_id: @race_user.id).delete_all
        ExternalSubscription.where(user_id: @race_user.id).destroy_all
        @race_user.destroy!
      end
    end

    it 'rejects the stale revision after the holder commits' do
      @race_user = Fabricate(:user)
      enable_external_bridge_feeds!(@race_user)
      raced = external_project_for(@race_user, body: 'Race article')
      ready = Queue.new
      release = Queue.new
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ExternalSubscription.transaction do
            locked = ExternalSubscription.lock.find(raced[:subscription].id)
            ExternalFeedRoute.create!(user: @race_user, external_subscription: locked, destination: 'home')
            locked.update_columns(feed_routes_revision: 1, updated_at: Time.current)
            ready << true
            release.pop
          end
        end
      end
      ready.pop
      error = Queue.new
      racer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.new.call(
            user: @race_user,
            subscription_id: raced[:subscription].id,
            home: false,
            list_ids: [],
            expected_revision: 0
          )
          error << nil
        rescue ExternalBridge::Error => e
          error << e
        end
      end
      sleep 0.3
      release << true
      holder.join
      racer.join

      failure = error.pop
      expect(failure).to be_a(ExternalBridge::Error)
      expect(failure.code).to eq 'stale_feed_routes'
      expect(ExternalFeedRoute.where(external_subscription_id: raced[:subscription].id).pluck(:destination)).to eq ['home']
      expect(raced[:subscription].reload.feed_routes_revision).to eq 1
    end
  end
end
