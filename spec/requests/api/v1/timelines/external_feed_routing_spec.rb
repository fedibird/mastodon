# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External feed routing on home and list REST' do
  BASE = 9_007_199_254_741_000

  def capture_sql
    queries = []
    callback = lambda do |*, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == 'SCHEMA' || sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)

      queries << sql
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries
  end

  def save_route(user, subscription, home:, list_ids: [])
    ExternalBridge::FeedRoutes::Update.new.call(
      user: user,
      subscription_id: subscription.id,
      home: home,
      list_ids: list_ids,
      expected_revision: subscription.reload.feed_routes_revision
    )
  end

  def plant_ordinary(account, id, text)
    status = Fabricate(:status, id: id, account: account, visibility: :public, text: text)
    redis.zadd(FeedManager.instance.key(:home, account.id), [[status.id, status.id]])
    status
  end

  def link_param(name)
    href = response.headers['Link'].links.map(&:href).find { |value| value.include?("#{name}=") }
    Rack::Utils.parse_query(URI(href).query)[name]
  end

  def marker_picks(queries)
    queries.count do |sql|
      normalized = sql.downcase
      normalized.include?('external_status_projections') &&
        normalized.match?(/\blimit\b/) &&
        normalized.match?(/status_id/) &&
        !normalized.match?(/\bin\b/)
    end
  end

  def home_rows(params = {})
    get '/api/v1/timelines/home', params: params, headers: owner_headers
    rows = if params[:compact].present?
             body_as_json.fetch(:statuses)
           else
             body_as_json
           end
    rows
  end

  after do
    Setting.external_bridge_feeds = false
    Setting.external_bridge_feeds_testers = ''
    Setting.external_bridge_rss = false
    Setting.external_bridge_rss_testers = ''
  end

  let(:owner) { Fabricate(:user, account: Fabricate(:account, username: 'feedowner')) }
  let(:roommate) { share_account_user(owner.account) }
  let(:stranger) { Fabricate(:user) }
  let(:admin) { user_with_role('Owner') }
  let(:owner_headers) { auth_headers_for(owner, 'read:statuses read:lists write:favourites write:bookmarks') }
  let(:external_body) { 'external-route-article' }
  let(:bundle) { external_project_for(owner, body: external_body, id: 9_007_199_254_740_993) }

  before do
    enable_external_bridge_feeds!(owner)
    bundle
    save_route(owner, bundle[:subscription], home: true)
  end

  describe 'GET /api/v1/timelines/home' do
    it 'returns direct plus external to the owner in json and compact, with the 64-bit id intact' do
      ordinary = plant_ordinary(owner.account, BASE + 9, 'ordinary-home-article')

      get '/api/v1/timelines/home', headers: owner_headers

      expect(response).to have_http_status(200)
      row = body_as_json.find { |item| item[:id] == bundle[:status].id.to_s }
      expect(row[:visibility]).to eq 'direct'
      expect(row[:visibility_ex]).to eq 'external'
      expect(row[:reblogged]).to be false
      expect(row[:fedibird_external]).to include(interaction: 'local_only', protocol: 'rss')
      expect(body_as_json.map { |item| item[:id] }).to include(ordinary.id.to_s, bundle[:status].id.to_s)
      expect(response.body).to include(%("#{bundle[:status].id}"))
      expect(response.body).not_to include('"visibility":"external"')

      get '/api/v1/timelines/home', params: { compact: true }, headers: owner_headers

      expect(response).to have_http_status(200)
      compact_row = body_as_json[:statuses].find { |item| item[:id] == bundle[:status].id.to_s }
      expect(compact_row[:visibility]).to eq 'direct'
      expect(compact_row[:visibility_ex]).to eq 'external'
      expect(compact_row[:fedibird_external][:interaction]).to eq 'local_only'
    end

    it 'shows the owner favourite and bookmark and hides the row from everyone else' do
      post "/api/v1/statuses/#{bundle[:status].id}/favourite", headers: owner_headers
      post "/api/v1/statuses/#{bundle[:status].id}/bookmark", headers: owner_headers

      get '/api/v1/timelines/home', headers: owner_headers

      row = body_as_json.find { |item| item[:id] == bundle[:status].id.to_s }
      expect(row[:favourited]).to be true
      expect(row[:bookmarked]).to be true

      [auth_headers_for(roommate), auth_headers_for(stranger), auth_headers_for(admin, 'read:statuses admin:read'), {}].each do |headers|
        get '/api/v1/timelines/home', headers: headers
        expect(response.body).not_to include(external_body)
        expect(response.body).not_to include(bundle[:status].id.to_s)
      end
    end

    it 'keeps the existing oauth scopes' do
      get '/api/v1/timelines/home', headers: auth_headers_for(owner, 'read:lists')
      expect(response).to have_http_status(403)

      get '/api/v1/timelines/home', headers: owner_headers
      expect(response).to have_http_status(200)
    end

    it 'filters on the stored visibility, not the direct mask' do
      plant_ordinary(owner.account, BASE + 4, 'ordinary-public-article')
      personal = Fabricate(:status, id: BASE + 3, account: owner.account, visibility: :personal, text: 'ordinary-personal-article')
      redis.zadd(FeedManager.instance.key(:home, owner.account_id), [[personal.id, personal.id]])

      expect(home_rows.map { |row| row[:id] }).to include(bundle[:status].id.to_s, personal.id.to_s)

      expect(home_rows(visibilities: ['external']).map { |row| row[:id] }).to eq [bundle[:status].id.to_s]
      expect(home_rows(visibilities: ['public']).map { |row| row[:content].to_s }.join).to include('ordinary-public-article')
      expect(home_rows(visibilities: ['public']).map { |row| row[:id] }).not_to include(bundle[:status].id.to_s)
      expect(home_rows(visibilities: ['direct']).map { |row| row[:id] }).not_to include(bundle[:status].id.to_s)
      expect(home_rows(visibilities: ['personal']).map { |row| row[:id] }).to eq [personal.id.to_s]
      webui = home_rows(visibilities: %w(public unlisted private limited direct personal))
      expect(webui.map { |row| row[:id] }).not_to include(bundle[:status].id.to_s)
      expect(home_rows(visibilities: ['201']).map { |row| row[:id] }).not_to include(bundle[:status].id.to_s)
    end

    it 'omits ineligible shapes and still reads a paused canonical row when rss fetch is off' do
      legacy = external_project_for(owner, body: 'legacy-personal-projection', visibility: :personal)
      removed = external_project_for(owner, body: 'source-deleted-projection', source_deleted: true)
      paused = external_project_for(owner, body: 'paused-canonical-projection', state: 'paused')
      [legacy, removed, paused].each { |row| save_route(owner, row[:subscription], home: true) }
      Status.create!(
        account: owner.account,
        text: 'orphan-external-phrase',
        visibility: :external,
        searchability: :personal,
        local: true,
        external_projection: true,
        uri: nil,
        reply: false
      )
      Setting.external_bridge_rss = false

      get '/api/v1/timelines/home', headers: owner_headers

      expect(response.body).to include('paused-canonical-projection')
      expect(response.body).to include(external_body)
      expect(response.body).not_to include('legacy-personal-projection')
      expect(response.body).not_to include('source-deleted-projection')
      expect(response.body).not_to include('orphan-external-phrase')
    end

    it 'leaves the ordinary path when delivery is off or the user is not listed' do
      ordinary = plant_ordinary(owner.account, BASE + 2, 'flag-off-ordinary')
      Setting.external_bridge_feeds = false

      get '/api/v1/timelines/home', headers: owner_headers

      expect(response).to have_http_status(200)
      expect(response.body).to include('flag-off-ordinary')
      expect(response.body).not_to include(external_body)
      expect(ExternalFeedRoute.where(external_subscription_id: bundle[:subscription].id)).to exist
      expect(ordinary.id).to be_present

      Setting.external_bridge_feeds = true
      Setting.external_bridge_feeds_testers = stranger.id.to_s
      get '/api/v1/timelines/home', headers: owner_headers
      expect(response.body).not_to include(external_body)
    end

    it 'paginates an interleaved page with max, since, and min' do
      # Redis scores are IEEE doubles. These ids sit above 2^53 and stay
      # exactly representable, so exclusive bounds do not collapse.
      anchor = 9_007_199_254_740_992
      ordinary_ids = [64, 96, 128, 160].map { |offset| anchor + offset }
      external_ids = [80, 112, 144, 176].map { |offset| anchor + offset }
      ordinary_ids.each { |id| plant_ordinary(owner.account, id, "ordinary #{id}") }
      external_ids.each do |id|
        row = external_project_for(owner, id: id, body: "external #{id}")
        save_route(owner, row[:subscription], home: true)
      end

      expect(home_rows(limit: 4).map { |row| row[:id] }).to eq external_ids.reverse.zip(ordinary_ids.reverse).flatten.first(4).map(&:to_s)

      next_page = home_rows(limit: 4, max_id: anchor + 128)
      expect(next_page.map { |row| row[:id] }).to eq [anchor + 112, anchor + 96, anchor + 80, anchor + 64].map(&:to_s)

      since_page = home_rows(limit: 2, since_id: anchor + 112)
      expect(since_page.map { |row| row[:id] }).to eq [anchor + 176, anchor + 160].map(&:to_s)

      min_page = home_rows(limit: 3, min_id: anchor + 80)
      expect(min_page.map { |row| row[:id] }).to eq [anchor + 128, anchor + 112, anchor + 96].map(&:to_s)

      both = home_rows(limit: 2, max_id: anchor + 160, min_id: anchor + 80)
      expect(both.map { |row| row[:id] }).to eq [anchor + 112, anchor + 96].map(&:to_s)

      get '/api/v1/timelines/home', params: { max_id: 1 }, headers: owner_headers
      expect(response).to have_http_status(200)
      expect(body_as_json).to eq []
      expect(response.headers['Link']).to be_blank
    end

    it 'follows an external max_id onto the ordinary status that shares its Redis score' do
      base = 9_007_199_254_740_992
      expect(bundle[:status].id).to eq(base + 1)
      expect((base + 1).to_f).to eq(base.to_f)
      plant_ordinary(owner.account, base, 'score neighbour')

      expect(home_rows(limit: 1).map { |row| row[:id] }).to eq [(base + 1).to_s]
      max_id = link_param('max_id')
      expect(max_id).to eq((base + 1).to_s)

      expect(home_rows(limit: 1, max_id: max_id).map { |row| row[:id] }).to eq [base.to_s]
    end

    it 'follows min_id, since_id, and the combined window across a collapsed score' do
      base = 9_007_199_254_740_992
      boundary = base + 3
      neighbour = base + 4
      expect(boundary.to_f).to eq(neighbour.to_f)
      row = external_project_for(owner, id: boundary, body: 'min boundary')
      save_route(owner, row[:subscription], home: true)
      plant_ordinary(owner.account, neighbour, 'min neighbour')

      expect(home_rows(limit: 1, max_id: neighbour).map { |item| item[:id] }).to eq [boundary.to_s]
      min_id = link_param('min_id')
      expect(min_id).to eq(boundary.to_s)
      expect(home_rows(limit: 1, min_id: min_id).map { |item| item[:id] }).to eq [neighbour.to_s]
      expect(home_rows(limit: 1, since_id: boundary).map { |item| item[:id] }).to eq [neighbour.to_s]
      expect(home_rows(limit: 1, max_id: neighbour + 1, min_id: boundary).map { |item| item[:id] }).to eq [neighbour.to_s]
    end

    it 'pages ordinary members that share one score' do
      base = 9_007_199_254_740_992
      bucket = [base + 5, base + 6, base + 7]
      expect(bucket.map(&:to_f).uniq.size).to eq 1
      bucket.each { |id| plant_ordinary(owner.account, id, "bucket #{id}") }

      cursor = nil
      seen = []
      bucket.size.times do
        params = { limit: 1 }
        params[:max_id] = cursor if cursor
        rows = home_rows(params)
        expect(rows.size).to eq 1
        seen << rows.first[:id]
        cursor = link_param('max_id')
        expect(cursor).to eq rows.first[:id]
      end

      expect(seen).to eq bucket.sort.reverse.map(&:to_s)
    end

    it 'keeps visibilities and compact on the link header and stays 206 while home regenerates' do
      plant_ordinary(owner.account, BASE + 11, 'rebuilding ordinary')
      get '/api/v1/timelines/home', params: { limit: 5, compact: true, visibilities: ['external'] }, headers: owner_headers

      hrefs = response.headers['Link'].links.map(&:href).join(' ')
      expect(hrefs).to include('compact=true')
      expect(hrefs).to include('visibilities')
      expect(hrefs).to include('external')
      expect(hrefs).to include(bundle[:status].id.to_s)

      redis.set("account:#{owner.account_id}:regeneration", '1')
      get '/api/v1/timelines/home', headers: owner_headers

      expect(response).to have_http_status(206)
      expect(response.body).to include('rebuilding ordinary')
      expect(response.body).not_to include(external_body)

      redis.del(FeedManager.instance.key(:home, owner.account_id))
      get '/api/v1/timelines/home', headers: owner_headers
      expect(response).to have_http_status(206)
      expect(response.body).not_to include(external_body)
    end

    it 'drops an external id that fails the post-hydrate check and does not fill the hole' do
      plant_ordinary(owner.account, BASE + 12, 'surviving ordinary')
      allow_any_instance_of(ExternalBridge::Feeds::Query).to receive(:eligible_ids).and_return([])

      get '/api/v1/timelines/home', headers: owner_headers

      expect(response).to have_http_status(200)
      expect(response.body).to include('surviving ordinary')
      expect(response.body).not_to include(external_body)
    end

    it 'does not query membership when delivery is off or the visibility filter excludes external' do
      plant_ordinary(owner.account, BASE + 1, 'counted ordinary')
      get '/api/v1/timelines/home', params: { limit: 1 }, headers: owner_headers

      Setting.external_bridge_feeds = false
      off = capture_sql { get '/api/v1/timelines/home', headers: owner_headers }
      expect(off.none? { |sql| sql.include?('external_feed_routes') }).to be true
      expect(off.none? { |sql| sql.match?(/JOIN external_status_projections/i) }).to be true

      Setting.external_bridge_feeds = true
      permit_external_bridge_feeds_testers!(owner)
      public_only = capture_sql { get '/api/v1/timelines/home', params: { visibilities: ['public'] }, headers: owner_headers }
      expect(public_only.none? { |sql| sql.include?('external_feed_routes') }).to be true
    end

    it 'selects membership once for a page of 20 and a page of 40' do
      40.times do |offset|
        row = external_project_for(owner, id: 8_100_000_000_000 + offset, body: "bulk #{offset}")
        save_route(owner, row[:subscription], home: true)
      end
      get '/api/v1/timelines/home', params: { limit: 1 }, headers: owner_headers

      twenty = capture_sql { get '/api/v1/timelines/home', params: { limit: 20 }, headers: owner_headers }
      forty = capture_sql { get '/api/v1/timelines/home', params: { limit: 40 }, headers: owner_headers }
      route_reads = ->(queries) { queries.count { |sql| sql.match?(/select/i) && sql.include?('external_feed_routes') } }
      marker_reads = ->(queries) { queries.count { |sql| sql.match?(/select/i) && sql.include?('external_status_projections') } }

      expect(route_reads.call(twenty)).to be_between(1, 3)
      expect(route_reads.call(forty)).to eq route_reads.call(twenty)
      expect(marker_reads.call(twenty)).to be <= 6
      expect(marker_reads.call(forty)).to be <= marker_reads.call(twenty) + 1
      expect(body_as_json.size).to eq 40
    end

    it 'does not pick a marker per ordinary status on a mixed page' do
      external = external_project_for(owner, id: BASE + 400, body: 'mixed external')
      save_route(owner, external[:subscription], home: true)
      39.times { |offset| plant_ordinary(owner.account, BASE + 100 + (offset * 2), "mixed ordinary #{offset}") }

      ordinary = capture_sql { get '/api/v1/timelines/home', params: { limit: 20, max_id: external[:status].id }, headers: owner_headers }
      expect(body_as_json.size).to eq 20
      expect(body_as_json.map { |row| row[:id] }).not_to include(external[:status].id.to_s)
      expect(marker_picks(ordinary)).to eq 0

      external_only = capture_sql { get '/api/v1/timelines/home', params: { limit: 20, visibilities: ['external'] }, headers: owner_headers }
      expect(body_as_json.map { |row| row[:id] }).to include(external[:status].id.to_s)
      expect(marker_picks(external_only)).to eq 0

      mixed_19 = capture_sql { get '/api/v1/timelines/home', params: { limit: 20 }, headers: owner_headers }
      expect(body_as_json.size).to eq 20
      expect(body_as_json.count { |row| row[:visibility_ex] == 'external' }).to eq 1
      mixed_39 = capture_sql { get '/api/v1/timelines/home', params: { limit: 40 }, headers: owner_headers }
      expect(body_as_json.size).to eq 40
      expect(body_as_json.count { |row| row[:visibility_ex] == 'external' }).to eq 1
      compact_19 = capture_sql { get '/api/v1/timelines/home', params: { limit: 20, compact: true }, headers: owner_headers }
      expect(body_as_json[:statuses].size).to eq 20
      compact_39 = capture_sql { get '/api/v1/timelines/home', params: { limit: 40, compact: true }, headers: owner_headers }
      expect(body_as_json[:statuses].size).to eq 40
      marker_reads = ->(queries) { queries.count { |sql| sql.match?(/select/i) && sql.include?('external_status_projections') } }

      [mixed_19, mixed_39, compact_19, compact_39].each { |queries| expect(marker_picks(queries)).to eq 0 }
      expect(marker_reads.call(mixed_19)).to be < 19
      expect(marker_reads.call(mixed_39)).to be <= marker_reads.call(mixed_19) + 2
      expect(marker_reads.call(compact_39)).to be <= marker_reads.call(compact_19) + 2
    end

    it 'does not read membership per status when a permitted user has no route' do
      ExternalFeedRoute.where(user_id: owner.id).delete_all
      5.times { |offset| plant_ordinary(owner.account, BASE + 500 + offset, "unrouted #{offset}") }

      queries = capture_sql { get '/api/v1/timelines/home', params: { limit: 20 }, headers: owner_headers }
      route_reads = queries.count { |sql| sql.match?(/select/i) && sql.include?('external_feed_routes') }

      expect(response).to have_http_status(200)
      expect(body_as_json.size).to eq 5
      expect(marker_picks(queries)).to eq 0
      expect(route_reads).to eq 1
      expect(queries.none? { |sql| sql.match?(/JOIN external_status_projections/i) }).to be true
    end
  end

  describe 'GET /api/v1/timelines/list/:id' do
    let(:list) { Fabricate(:list, account: owner.account, title: 'Delivery') }

    it 'returns the list route to the owner and not the roommate who shares the account' do
      listed = external_project_for(owner, body: 'list-route-article')
      save_route(owner, listed[:subscription], home: false, list_ids: [list.id])
      ordinary = Fabricate(:status, account: owner.account, visibility: :public, text: 'list-ordinary-article')
      redis.zadd(FeedManager.instance.key(:list, list.id), [[ordinary.id, ordinary.id]])

      get "/api/v1/timelines/list/#{list.id}", headers: owner_headers

      expect(response).to have_http_status(200)
      expect(body_as_json.map { |row| row[:id] }).to include(listed[:status].id.to_s, ordinary.id.to_s)
      row = body_as_json.find { |item| item[:id] == listed[:status].id.to_s }
      expect(row[:visibility]).to eq 'direct'
      expect(row[:visibility_ex]).to eq 'external'

      get "/api/v1/timelines/list/#{list.id}", params: { compact: true }, headers: owner_headers
      expect(body_as_json[:statuses].map { |item| item[:id] }).to include(listed[:status].id.to_s)

      get "/api/v1/timelines/list/#{list.id}", headers: auth_headers_for(roommate, 'read:lists')
      expect(response.body).not_to include('list-route-article')

      get '/api/v1/timelines/home', headers: owner_headers
      expect(response.body).not_to include('list-route-article')

      get "/api/v1/timelines/list/#{list.id}", headers: auth_headers_for(owner, 'read:statuses')
      expect(response).to have_http_status(403)
    end
  end

  describe 'privacy side effects' do
    it 'does not publish, notify, or index while saving a route or reading home' do
      expect(DistributionWorker).not_to receive(:perform_async)
      expect(ActivityPub::DistributionWorker).not_to receive(:perform_async)
      expect(ActivityPub::StatusUpdateDistributionWorker).not_to receive(:perform_async)
      expect(Webhooks::DeliveryWorker).not_to receive(:perform_async)

      notifications = Notification.count
      list = Fabricate(:list, account: owner.account)
      save_route(owner, bundle[:subscription], home: true, list_ids: [list.id])
      get '/api/v1/timelines/home', headers: owner_headers
      get '/api/v1/timelines/public', headers: owner_headers
      get '/api/v1/timelines/personal', headers: owner_headers

      expect(Notification.count).to eq notifications
      expect(redis.zscore(FeedManager.instance.key(:home, owner.account_id), bundle[:status].id)).to be_nil
      expect(PushUpdateWorker.new.perform(owner.account_id, bundle[:status].id)).to be true
      expect(bundle[:status].search_indexable?).to be false
      expect(response.body).not_to include(external_body)
    end

    it 'does not resolve the external status through home seek' do
      post '/api/v1/timelines/seek', params: {
        version: 1,
        preference: 'nearest',
        source: 'home',
        kind: 'status',
        seek_target: { id: bundle[:status].id.to_s },
        context: { only_media: false, without_media: false, without_bot: false },
      }, headers: owner_headers

      expect(response.body).not_to include(external_body)
    end
  end
end
