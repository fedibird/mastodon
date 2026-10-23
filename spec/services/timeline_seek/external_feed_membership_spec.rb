# frozen_string_literal: true

require 'rails_helper'

describe 'External feed membership for home and list' do
  def save_route(user, subscription, home:, list_ids: [])
    ExternalBridge::FeedRoutes::Update.new.call(
      user: user,
      subscription_id: subscription.id,
      home: home,
      list_ids: list_ids,
      expected_revision: subscription.reload.feed_routes_revision
    )
  end

  def classify(user, source:, ids:, context: {})
    TimelineSeek::Membership.new(user.account, user: user).call(
      version: 1,
      source: source,
      context: context,
      ids: ids
    )
  end

  def outcomes(result)
    result.to_h[:results].index_by { |row| row[:id] }
  end

  def capture_sql
    sqls = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
      sqls << payload[:sql].to_s
    end
    yield
    sqls
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def projection_selects(sqls)
    sqls.count { |sql| sql.match?(/\ASELECT/i) && sql.include?('external_status_projections') }
  end

  let(:user) { Fabricate(:user) }
  let(:author) { Fabricate(:user).account }

  after do
    Setting.external_bridge_feeds = false
    Setting.external_bridge_feeds_testers = ''
    redis.del("account:#{user.account_id}:regeneration")
  end

  it 'treats a routed external row as a member and an ordinary redis miss as unknown' do
    enable_external_bridge_feeds!(user)
    external = external_project_for(user, id: 9_007_199_254_740_993)
    save_route(user, external[:subscription], home: true)
    ordinary = Fabricate(:status, account: author, visibility: :public)

    result = classify(user, source: 'home', ids: [external[:status].id.to_s, ordinary.id.to_s], context: { visibilities: ['public', 'external'] })
    rows = outcomes(result)

    expect(rows[external[:status].id.to_s][:outcome]).to eq('member')
    expect(rows[ordinary.id.to_s][:outcome]).to eq('unknown')
    expect(rows[ordinary.id.to_s][:reason]).to eq('outside_retained_range')
    expect(result.outcome).to eq('partial')
    expect(result.limitations).to include('external_db_membership')
    expect(external[:status].id.to_s).to eq('9007199254740993')
  end

  it 'does not use not_in_source for another user, an administrator, or a mismatched viewer' do
    enable_external_bridge_feeds!(user)
    external = external_project_for(user)
    save_route(user, external[:subscription], home: true)
    other = share_account_user(user.account)
    admin = Fabricate(:user, role: UserRole.find_by!(name: 'Admin'))
    enable_external_bridge_feeds!(other, admin)

    [other, admin].each do |visitor|
      row = outcomes(classify(visitor, source: 'home', ids: [external[:status].id.to_s]))[external[:status].id.to_s]

      expect(row[:outcome]).to eq('not_found')
      expect(row[:reason]).not_to eq('external_not_delivered')
    end

    mismatched = ExternalBridge::Viewer.with_user(other.id) do
      TimelineSeek::Membership.new(user.account, user: user).call(
        version: 1,
        source: 'home',
        context: {},
        ids: [external[:status].id.to_s]
      )
    end

    expect(outcomes(mismatched)[external[:status].id.to_s][:outcome]).to eq('not_found')
  end

  it 'withholds a route removal, a source deletion, a legacy row, a flag-off row, and a visibility filter' do
    enable_external_bridge_feeds!(user)
    routed = external_project_for(user)
    removed = external_project_for(user)
    deleted = external_project_for(user, source_deleted: true)
    legacy = external_project_for(user, visibility: :personal)
    save_route(user, routed[:subscription], home: true)
    save_route(user, removed[:subscription], home: true)
    save_route(user, removed[:subscription], home: false)
    save_route(user, deleted[:subscription], home: true)
    save_route(user, legacy[:subscription], home: true)

    flagged = outcomes(classify(user, source: 'home', ids: [routed[:status].id.to_s, removed[:status].id.to_s, deleted[:status].id.to_s, legacy[:status].id.to_s]))
    expect(flagged[routed[:status].id.to_s][:outcome]).to eq('member')
    [removed, deleted, legacy].each do |row|
      expect(flagged[row[:status].id.to_s]).to include(outcome: 'not_in_source', reason: 'external_not_delivered')
    end

    filtered = outcomes(classify(user, source: 'home', ids: [routed[:status].id.to_s], context: { visibilities: ['public'] }))
    expect(filtered[routed[:status].id.to_s]).to include(outcome: 'not_in_source', reason: 'external_not_delivered')

    Setting.external_bridge_feeds = false
    hidden = outcomes(classify(user, source: 'home', ids: [routed[:status].id.to_s]))
    expect(hidden[routed[:status].id.to_s]).to include(outcome: 'not_in_source', reason: 'external_not_delivered')
    expect(Status.where(id: routed[:status].id)).to exist
  end

  it 'defers an eligible external row while home is regenerating and keeps it out of limited' do
    enable_external_bridge_feeds!(user)
    external = external_project_for(user)
    save_route(user, external[:subscription], home: true)
    redis.set("account:#{user.account_id}:regeneration", '1')

    deferred = outcomes(classify(user, source: 'home', ids: [external[:status].id.to_s]))
    expect(deferred[external[:status].id.to_s]).to include(outcome: 'unknown', reason: 'feed_regenerating')

    redis.del("account:#{user.account_id}:regeneration")
    limited = outcomes(classify(user, source: 'limited', ids: [external[:status].id.to_s], context: { visibilities: ['public'] }))
    expect(limited[external[:status].id.to_s][:outcome]).to eq('unknown')
    expect(limited[external[:status].id.to_s][:reason]).not_to eq('external_not_delivered')
  end

  it 'uses the same external membership for a list and for seek' do
    enable_external_bridge_feeds!(user)
    list = Fabricate(:list, account: user.account)
    external = external_project_for(user)
    save_route(user, external[:subscription], home: false, list_ids: [list.id])

    listed = outcomes(classify(user, source: 'list', ids: [external[:status].id.to_s], context: { id: list.id.to_s }))
    expect(listed[external[:status].id.to_s][:outcome]).to eq('member')

    sought = TimelineSeek::Resolver.new(user.account, user: user).call(
      version: 1,
      source: 'list',
      kind: 'status',
      preference: 'nearest',
      context: { id: list.id.to_s },
      seek_target: { id: external[:status].id.to_s }
    )

    expect(sought.outcome).to eq('resolved')
    expect(sought.anchor_id).to eq(external[:status].id.to_s)
    expect(sought.limitations).to include('external_db_membership')
  end

  it 'classifies 20 and 40 mixed ids with the same projection reads' do
    enable_external_bridge_feeds!(user)
    build = lambda do |count|
      ordinary = Array.new(count) { Fabricate(:status, account: author, visibility: :public) }
      external = Array.new(count) do
        row = external_project_for(user)
        save_route(user, row[:subscription], home: true)
        row[:status]
      end
      (ordinary + external).map { |status| status.id.to_s }
    end

    ids20 = build.call(10)
    sql20 = capture_sql { @rows20 = classify(user, source: 'home', ids: ids20, context: { visibilities: ['public', 'external'] }) }
    ids40 = build.call(20)
    sql40 = capture_sql { @rows40 = classify(user, source: 'home', ids: ids40, context: { visibilities: ['public', 'external'] }) }

    expect(@rows20.to_h[:results].size).to eq(20)
    expect(@rows40.to_h[:results].size).to eq(40)
    expect(@rows20.to_h[:results].count { |row| row[:outcome] == 'member' }).to eq(10)
    expect(@rows40.to_h[:results].count { |row| row[:outcome] == 'member' }).to eq(20)
    expect(projection_selects(sql20)).to eq(projection_selects(sql40))
    expect(projection_selects(sql20)).to be <= 6
    expect(projection_selects(sql20)).to be < 20
  end

  it 'keeps a positional bookmark on its timeline when the route no longer delivers the anchor' do
    enable_external_bridge_feeds!(user)
    external = external_project_for(user)
    bookmark = TimelineReadingBookmark.create!(
      user: user,
      name: 'Evening',
      source: 'home',
      context: {},
      anchor_status_id: external[:status].id.to_s,
      offset_px: 0,
      alignment: 'top'
    )

    payload = TimelineReadingBookmarks::Presenter.new(user).one(bookmark)

    expect(bookmark.reload.source).to eq('home')
    expect(payload[:source]).to eq('home')
    expect(payload[:availability][:membership]).to eq('not_in_source')
    expect(payload[:availability][:reason]).to eq('external_not_delivered')
    expect(payload.to_json).not_to include(external[:status].text)
  end

  it 'does not let a redis copy of an external id outrank placement' do
    enable_external_bridge_feeds!(user)
    external = external_project_for(user)
    deleted = external_project_for(user, source_deleted: true)
    ordinary = Fabricate(:status, account: author, visibility: :public)
    key = FeedManager.instance.key(:home, user.account_id)
    redis.zadd(key, external[:status].id, external[:status].id)
    redis.zadd(key, deleted[:status].id, deleted[:status].id)
    save_route(user, deleted[:subscription], home: true)
    feed = HomeFeed.new(user.account)
    visibilities = %w(public external)

    compose = lambda do
      ExternalBridge::Feeds::Compose.new(user: user, feed: feed, destination: 'home').call(20, nil, nil, nil, visibilities).map(&:id)
    end
    seek = lambda do |status|
      TimelineSeek::Resolver.new(user.account, user: user).call(
        version: 1,
        source: 'home',
        kind: 'status',
        preference: 'nearest',
        context: { visibilities: visibilities },
        seek_target: { id: status.id.to_s }
      )
    end
    account_seek = lambda do
      TimelineSeek::Resolver.new(user.account, user: user).call(
        version: 1,
        source: 'home',
        kind: 'account',
        preference: 'nearest',
        context: { visibilities: visibilities },
        seek_target: { account_id: user.account_id.to_s }
      )
    end
    rows_for = lambda do
      outcomes(classify(user, source: 'home', ids: [external[:status].id.to_s, deleted[:status].id.to_s, ordinary.id.to_s], context: { visibilities: visibilities }))
    end

    expect(compose.call).not_to include(external[:status].id)
    expect(seek.call(external[:status]).outcome).to eq('not_in_source')
    expect(seek.call(external[:status]).reason).to eq('external_not_delivered')
    expect(rows_for.call[external[:status].id.to_s]).to include(outcome: 'not_in_source', reason: 'external_not_delivered')
    expect(rows_for.call[deleted[:status].id.to_s]).to include(outcome: 'not_in_source', reason: 'external_not_delivered')
    expect(rows_for.call[ordinary.id.to_s]).to include(outcome: 'unknown', reason: 'outside_retained_range')
    expect(account_seek.call.anchor_id).not_to eq(external[:status].id.to_s)

    save_route(user, external[:subscription], home: true)
    expect(compose.call).to include(external[:status].id)
    expect(seek.call(external[:status]).outcome).to eq('resolved')
    expect(rows_for.call[external[:status].id.to_s][:outcome]).to eq('member')
    expect(account_seek.call.anchor_id).to eq(external[:status].id.to_s)

    save_route(user, external[:subscription], home: false)
    expect(compose.call).not_to include(external[:status].id)
    expect(seek.call(external[:status]).outcome).to eq('not_in_source')
    expect(rows_for.call[external[:status].id.to_s][:outcome]).to eq('not_in_source')

    redis.set("account:#{user.account_id}:regeneration", '1')
    save_route(user, external[:subscription], home: true)
    expect(compose.call).not_to include(external[:status].id)
    expect(seek.call(external[:status]).outcome).to eq('unavailable')
    expect(seek.call(external[:status]).reason).to eq('feed_regenerating')
    expect(rows_for.call[external[:status].id.to_s]).to include(outcome: 'unknown', reason: 'feed_regenerating')
    redis.del("account:#{user.account_id}:regeneration")

    Setting.external_bridge_feeds = false
    expect(compose.call).not_to include(external[:status].id)
    expect(seek.call(external[:status]).outcome).to eq('not_in_source')
    expect(rows_for.call[external[:status].id.to_s]).to include(outcome: 'not_in_source', reason: 'external_not_delivered')

    other = share_account_user(user.account)
    stranger = Fabricate(:user)
    [other, stranger].each do |visitor|
      row = outcomes(classify(visitor, source: 'home', ids: [external[:status].id.to_s], context: { visibilities: visibilities }))[external[:status].id.to_s]

      expect(row[:outcome]).to eq('not_found')
      expect(row[:reason]).not_to eq('external_not_delivered')
    end
  ensure
    redis.del(key) if key
  end
end
