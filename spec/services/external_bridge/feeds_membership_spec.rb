# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::Feeds::Query do
  def save_home(user, subscription, list_ids: [])
    ExternalBridge::FeedRoutes::Update.new.call(
      user: user,
      subscription_id: subscription.id,
      home: true,
      list_ids: list_ids,
      expected_revision: subscription.reload.feed_routes_revision
    )
  end

  def home_ids(user)
    described_class.new(user: user, destination: 'home').ids(limit: 20)
  end

  after do
    Setting.external_bridge_feeds = false
    Setting.external_bridge_feeds_testers = ''
  end

  let(:user) { Fabricate(:user) }

  before { enable_external_bridge_feeds!(user) }

  it 'returns a canonical external row once a home route exists, and not before' do
    bundle = external_project_for(user, body: 'Eligible article', id: 9_007_199_254_740_993)

    expect(home_ids(user)).to eq []

    save_home(user, bundle[:subscription])

    expect(home_ids(user)).to eq [bundle[:status].id]
    expect(bundle[:status].id).to eq 9_007_199_254_740_993
  end

  it 'keeps list routes off home and home routes off the list' do
    list = Fabricate(:list, account: user.account)
    home_only = external_project_for(user, body: 'Home only')
    list_only = external_project_for(user, body: 'List only')
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: home_only[:subscription].id, home: true, list_ids: [], expected_revision: 0)
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: list_only[:subscription].id, home: false, list_ids: [list.id], expected_revision: 0)

    expect(home_ids(user)).to eq [home_only[:status].id]
    expect(described_class.new(user: user, destination: 'list', list: list).ids(limit: 20)).to eq [list_only[:status].id]
  end

  it 'drops legacy personal, source-deleted, paused-independent rows stay, and another user of the same resource' do
    eligible = external_project_for(user, body: 'Still eligible', state: 'paused')
    legacy = external_project_for(user, body: 'Legacy personal', visibility: :personal)
    deleted = external_project_for(user, body: 'Source deleted', source_deleted: true)
    errored = external_project_for(user, body: 'Errored feed', state: 'error')
    [eligible, legacy, deleted, errored].each { |row| save_home(user, row[:subscription]) }

    roommate = share_account_user(user.account)
    enable_external_bridge_feeds!(roommate)
    roommate_row = external_project_for(roommate, body: 'Roommate copy')
    save_home(roommate, roommate_row[:subscription])

    expect(home_ids(user)).to contain_exactly(eligible[:status].id, errored[:status].id)
    expect(home_ids(roommate)).to eq [roommate_row[:status].id]
  end

  it 'returns nothing when delivery is off or the user is not a tester, and keeps the route' do
    bundle = external_project_for(user)
    save_home(user, bundle[:subscription])
    Setting.external_bridge_feeds = false

    expect(home_ids(user)).to eq []
    expect(ExternalFeedRoute.where(external_subscription_id: bundle[:subscription].id)).to exist

    Setting.external_bridge_feeds = true
    Setting.external_bridge_feeds_testers = ''
    expect(home_ids(user)).to eq []
  end

  it 'does not read a projection that was rolled back' do
    leaked_id = nil
    ApplicationRecord.transaction(requires_new: true) do
      created = external_project_for(user, body: 'Rolled back')
      save_home(user, created[:subscription])
      leaked_id = created[:status].id
      raise ActiveRecord::Rollback
    end

    expect(Status.where(id: leaked_id)).to be_empty
    expect(home_ids(user)).to eq []
  end

  it 'explains the home membership read on this database' do
    bundle = external_project_for(user, body: 'Explain row')
    save_home(user, bundle[:subscription])
    relation = described_class.new(user: user, destination: 'home').scope.reselect('statuses.id').distinct.order(Arel.sql('statuses.id DESC')).limit(20)

    plan = relation.explain

    expect(plan).to include('external_feed_routes')
    expect(plan).to include('external_status_projections')
  end
end

RSpec.describe ExternalBridge::Feeds::Compose do
  after do
    Setting.external_bridge_feeds = false
    Setting.external_bridge_feeds_testers = ''
  end

  let(:user) { Fabricate(:user) }
  let(:account) { user.account }

  before { enable_external_bridge_feeds!(user) }

  def plant(id, text)
    Fabricate(:status, id: id, account: account, visibility: :public, text: text)
  end

  it 'merges integer ids in walk order and hydrates one page' do
    ordinary = plant(30, 'ordinary thirty')
    older = plant(10, 'ordinary ten')
    external = external_project_for(user, id: 20, body: 'external twenty')
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: external[:subscription].id, home: true, list_ids: [], expected_revision: 0)
    redis.zadd(FeedManager.instance.key(:home, account.id), [[ordinary.id, ordinary.id], [older.id, older.id]])

    page = described_class.new(user: user, feed: HomeFeed.new(account), destination: 'home').call(3)

    expect(page.map(&:id)).to eq [30, 20, 10]
    expect(page.map(&:text)).to eq ['ordinary thirty', 'external twenty', 'ordinary ten']
  end

  it 'does not step past an unfinished redis frontier' do
    stub_const('FeedManager::MAX_ITEMS', 4)
    plant(50, 'fifty')
    plant(46, 'forty six')
    external = external_project_for(user, id: 10, body: 'older than the frontier')
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: external[:subscription].id, home: true, list_ids: [], expected_revision: 0)
    redis.zadd(FeedManager.instance.key(:home, account.id), [50, 49, 48, 47, 46].map { |id| [id, id] })

    page = described_class.new(user: user, feed: HomeFeed.new(account), destination: 'home').call(3)

    expect(page.map(&:id)).to eq [50]
    expect(page.map(&:id)).not_to include(10)
  end

  it 'reads external ids from an empty redis range and skips them while home is regenerating' do
    external = external_project_for(user, id: 80, body: 'external only')
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: external[:subscription].id, home: true, list_ids: [], expected_revision: 0)
    feed = HomeFeed.new(account)

    expect(described_class.new(user: user, feed: feed, destination: 'home').call(5).map(&:id)).to eq [80]

    plant(90, 'ordinary while rebuilding')
    redis.zadd(FeedManager.instance.key(:home, account.id), [[90, 90]])
    redis.set("account:#{account.id}:regeneration", '1')

    expect(described_class.new(user: user, feed: feed, destination: 'home').call(5).map(&:id)).to eq [90]
  end

  it 'keeps an external id that was also written into redis only once' do
    external = external_project_for(user, id: 70, body: 'once')
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: external[:subscription].id, home: true, list_ids: [], expected_revision: 0)
    redis.zadd(FeedManager.instance.key(:home, account.id), [[70, 70], [71, 71]])
    plant(71, 'neighbour')

    page = described_class.new(user: user, feed: HomeFeed.new(account), destination: 'home').call(5)

    expect(page.map(&:id)).to eq [71, 70]
  end

  it 'reads an older external id when a full scan budget ends on the last redis member' do
    stub_const('FeedManager::MAX_ITEMS', 4)
    external = external_project_for(user, id: 1, body: 'behind an exact budget')
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: external[:subscription].id, home: true, list_ids: [], expected_revision: 0)
    redis.zadd(FeedManager.instance.key(:home, account.id), [5, 4, 3, 2].map { |id| [id, id] })

    page = described_class.new(user: user, feed: HomeFeed.new(account), destination: 'home').call(20)

    expect(page.map(&:id)).to eq [1]
  end

  it 'reads an older external id when the redis range is shorter than the budget' do
    stub_const('FeedManager::MAX_ITEMS', 4)
    external = external_project_for(user, id: 1, body: 'behind a short range')
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: external[:subscription].id, home: true, list_ids: [], expected_revision: 0)
    redis.zadd(FeedManager.instance.key(:home, account.id), [4, 3].map { |id| [id, id] })

    page = described_class.new(user: user, feed: HomeFeed.new(account), destination: 'home').call(20)

    expect(page.map(&:id)).to eq [1]
  end

  it 'does not pull an older external id ahead of an ordinary status past the budget' do
    stub_const('FeedManager::MAX_ITEMS', 4)
    plant(6, 'inside the budget')
    plant(2, 'past the budget')
    external = external_project_for(user, id: 1, body: 'older than both')
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: external[:subscription].id, home: true, list_ids: [], expected_revision: 0)
    redis.zadd(FeedManager.instance.key(:home, account.id), [6, 5, 4, 3, 2].map { |id| [id, id] })
    feed = described_class.new(user: user, feed: HomeFeed.new(account), destination: 'home')

    expect(feed.call(20).map(&:id)).to eq [6]

    expect(feed.call(20, 6).map(&:id)).to eq [2, 1]
  end

  it 'does not treat unread redis members past the budget as the end of the range' do
    stub_const('FeedManager::MAX_ITEMS', 4)
    external = external_project_for(user, id: 1, body: 'still behind unread ids')
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: external[:subscription].id, home: true, list_ids: [], expected_revision: 0)
    redis.zadd(FeedManager.instance.key(:home, account.id), [6, 5, 4, 3, 2].map { |id| [id, id] })

    expect(described_class.new(user: user, feed: HomeFeed.new(account), destination: 'home').call(20)).to eq []
  end

  it 'reads external ids for an external-only filter without walking a full ordinary budget' do
    stub_const('FeedManager::MAX_ITEMS', 4)
    [5, 4, 3, 2].each { |id| plant(id, "ordinary #{id}") }
    external = external_project_for(user, id: 1, body: 'external only filter')
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: external[:subscription].id, home: true, list_ids: [], expected_revision: 0)
    redis.zadd(FeedManager.instance.key(:home, account.id), [5, 4, 3, 2].map { |id| [id, id] })

    page = described_class.new(user: user, feed: HomeFeed.new(account), destination: 'home').call(20, nil, nil, nil, ['external'])

    expect(page.map(&:id)).to eq [1]
  end

  it 'does not merge when the caller has no user' do
    external = external_project_for(user, id: 61, body: 'hidden from account feed')
    ExternalBridge::FeedRoutes::Update.new.call(user: user, subscription_id: external[:subscription].id, home: true, list_ids: [], expected_revision: 0)
    plant(60, 'ordinary sixty')
    redis.zadd(FeedManager.instance.key(:home, account.id), [[60, 60], [61, 61]])

    expect(HomeFeed.new(account).get(5).map(&:id)).to eq [60]
  end
end
