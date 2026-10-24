# frozen_string_literal: true

# The examples share one fixture matrix.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

RSpec.describe 'External source presentation on the owner REST extension' do
  def capture_sql(&block)
    queries = []
    callback = lambda do |*, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == 'SCHEMA' || sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)

      queries << sql.downcase.gsub(/\s+/, ' ')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    queries
  end

  def table_reads(queries, table)
    queries.count { |sql| sql.start_with?('select') && sql.match?(/from "#{table}"/) }
  end

  def attach_actor!(bundle, **attributes)
    actor = ExternalActor.create!({ protocol: 'rss', native_id: bundle[:source].canonical_key, display_name: 'Actor name', profile_url: 'https://actor.example/' }.merge(attributes))
    bundle[:resource].update!(external_actor: actor)
    actor
  end

  def save_route(user, subscription)
    ExternalBridge::FeedRoutes::Update.new.call(
      user: user,
      subscription_id: subscription.id,
      home: true,
      list_ids: [],
      expected_revision: subscription.reload.feed_routes_revision
    )
  end

  def presentation_for(headers, status)
    get "/api/v1/statuses/#{status.id}", headers: headers
    expect(response).to have_http_status(200)
    body_as_json[:fedibird_external][:presentation]
  end

  after do
    Setting.external_bridge_feeds = false
    Setting.external_bridge_feeds_testers = ''
  end

  let(:owner) { Fabricate(:user, account: Fabricate(:account, username: 'presowner', display_name: 'Owner Face')) }
  let(:roommate) { share_account_user(owner.account) }
  let(:stranger) { Fabricate(:user) }
  let(:admin) { user_with_role('Owner') }
  let(:owner_headers) { auth_headers_for(owner, 'read:statuses read:lists read:favourites read:bookmarks write:bookmarks write:favourites') }
  let(:bundle) { external_project_for(owner, body: 'Presented article') }
  let(:status) { bundle[:status] }

  describe 'canonical 201 projection' do
    it 'names the source and keeps the owner as the real account' do
      attach_actor!(bundle)
      get "/api/v1/statuses/#{status.id}", headers: owner_headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:visibility]).to eq 'direct'
      expect(body_as_json[:visibility_ex]).to eq 'external'
      expect(body_as_json[:account]).to include(id: owner.account_id.to_s, username: 'presowner', display_name: 'Owner Face')
      expect(body_as_json[:fedibird_external]).to include(protocol: 'rss', source_title: 'Public feed', byline_name: 'Ada', interaction: 'local_only')
      expect(body_as_json[:fedibird_external][:presentation]).to eq(
        kind: 'external_source',
        name: 'Public feed',
        subtitle: 'RSS',
        source_url: 'https://example.com',
        icon_url: nil,
        thumbnail_url: nil,
        byline_name: 'Ada'
      )
      expect(body_as_json[:fedibird_external][:presentation].to_json).not_to include('Owner Face')
      expect(body_as_json[:fedibird_external][:presentation].to_json).not_to include('presowner')
    end

    it 'labels an Atom source and never reuses the owner profile' do
      bundle[:source].update_columns(protocol: 'atom')
      bundle[:resource].update_columns(protocol: 'atom')

      presentation = presentation_for(owner_headers, status)

      expect(presentation[:subtitle]).to eq 'Atom'
      expect(presentation[:name]).to eq 'Public feed'
    end
  end

  describe 'legacy 200 projection' do
    it 'carries the same presentation for the marker owner' do
      legacy = project_for(owner, body: 'Legacy article')

      get "/api/v1/statuses/#{legacy[:status].id}", headers: owner_headers

      expect(response).to have_http_status(200)
      expect(body_as_json[:visibility_ex]).to eq 'personal'
      expect(body_as_json[:fedibird_external][:presentation]).to include(kind: 'external_source', name: 'Public feed', subtitle: 'RSS', source_url: 'https://example.com', byline_name: 'Ada')
    end
  end

  describe 'fallbacks' do
    it 'uses the actor name and profile url when the source has none' do
      bundle[:source].update_columns(title: nil, site_url: nil)
      attach_actor!(bundle)

      expect(presentation_for(owner_headers, status)).to include(name: 'Actor name', source_url: 'https://actor.example')
    end

    it 'falls back to the protocol label with no link when nothing public is known' do
      bundle[:source].update_columns(title: '   ', site_url: nil)
      bundle[:resource].update_columns(byline: nil)

      expect(presentation_for(owner_headers, status)).to include(name: 'RSS', subtitle: 'RSS', source_url: nil, icon_url: nil, thumbnail_url: nil, byline_name: nil)
    end

    it 'drops unsafe or invalid source urls instead of linking them' do
      ['javascript:alert(1)', 'ftp://example.com/', 'https://user:pw@example.com/', 'https://127.0.0.1/', 'not a url', 'https://example.com/?token=abc'].each do |value|
        bundle[:source].update_columns(site_url: value)
        expect(presentation_for(owner_headers, status)[:source_url]).to be_nil, "expected #{value.inspect} to be dropped"
      end
    end

    it 'cleans and bounds names and bylines without interpreting markup' do
      bundle[:source].update_columns(title: "<img src=x onerror=alert(1)>\u202Eevil\n#{'a' * 400}")
      bundle[:resource].update_columns(byline: "Ada\u0007\tLovelace #{'b' * 400}")

      presentation = presentation_for(owner_headers, status)

      expect(presentation[:name]).to start_with('<img src=x onerror=alert(1)>evil ')
      expect(presentation[:name]).not_to match(/[\u202E\n]/)
      expect(presentation[:name].length).to eq ExternalBridge::Presentation::NAME_LIMIT
      expect(presentation[:byline_name]).to start_with('Ada Lovelace')
      expect(presentation[:byline_name].length).to eq ExternalBridge::Presentation::BYLINE_LIMIT
    end

    it 'never exposes any stored avatar url as the icon in P1' do
      web = Rails.configuration.x.web_domain
      [
        'https://tracker.example/pixel.png?u=1',
        "https://#{web}/system/external/icon.png",
        "https://#{web}/redirect?to=https://tracker.example/pixel.png",
        "https://#{web}/media_proxy/1/original",
        "https://#{web}@tracker.example/icon.png",
        'http://localhost/icon.png',
        'data:image/png;base64,AAAA',
        'javascript:alert(1)',
      ].each do |value|
        actor = bundle[:resource].external_actor || attach_actor!(bundle)
        actor.update_columns(avatar_remote_url: value)
        presentation = presentation_for(owner_headers, status)

        expect(presentation[:icon_url]).to be_nil, "expected #{value.inspect} not to be exposed"
        expect(presentation[:thumbnail_url]).to be_nil
        expect(response.body).not_to include('tracker.example/pixel')
      end
    end
  end

  describe 'who can see it' do
    it 'gives nothing to the other user of the account, another user, an admin, or an anonymous request' do
      status

      [auth_headers_for(roommate), auth_headers_for(stranger), auth_headers_for(admin, 'read:statuses admin:read'), {}].each do |headers|
        get "/api/v1/statuses/#{status.id}", headers: headers
        expect(response).to have_http_status(404)
        expect(response.body).not_to include('presentation')
        expect(response.body).not_to include('Public feed')
      end
    end

    it 'omits the extension when the marker is missing' do
      orphan = Status.create!(
        account: owner.account, text: 'orphan article', visibility: :external, searchability: :personal,
        local: true, external_projection: true, uri: nil, reply: false
      )

      expect(ExternalBridge::ProjectionAccess.allow?(owner.id, Status.find(orphan.id))).to be false
      json = ActiveModelSerializers::SerializableResource.new(Status.find(orphan.id), serializer: REST::StatusSerializer, scope: owner, scope_name: :current_user).as_json
      expect(json).not_to have_key(:fedibird_external)
    end

    it 'does not serialize it for the same account under a different user scope' do
      status
      json = ActiveModelSerializers::SerializableResource.new(Status.find(status.id), serializer: REST::StatusSerializer, scope: roommate, scope_name: :current_user).as_json

      expect(json).not_to have_key(:fedibird_external)
    end

    it 'adds nothing to an ordinary status' do
      ordinary = Fabricate(:status, account: owner.account, visibility: :public, text: 'plain')

      get "/api/v1/statuses/#{ordinary.id}", headers: owner_headers

      expect(body_as_json).not_to have_key(:fedibird_external)
      expect(response.body).not_to include('external_source')
    end
  end

  describe 'every read path agrees' do
    before do
      attach_actor!(bundle)
      enable_external_bridge_feeds!(owner)
      save_route(owner, bundle[:subscription])
    end

    let(:expected) do
      { kind: 'external_source', name: 'Public feed', subtitle: 'RSS', source_url: 'https://example.com', icon_url: nil, thumbnail_url: nil, byline_name: 'Ada' }
    end

    it 'matches on home (full and compact), bookmarks, favourites, and the status read' do
      post "/api/v1/statuses/#{status.id}/bookmark", headers: owner_headers
      post "/api/v1/statuses/#{status.id}/favourite", headers: owner_headers

      get '/api/v1/timelines/home', headers: owner_headers
      expect(body_as_json.find { |row| row[:id] == status.id.to_s }.dig(:fedibird_external, :presentation)).to eq expected

      get '/api/v1/timelines/home', params: { compact: true }, headers: owner_headers
      compact_row = body_as_json[:statuses].find { |row| row[:id] == status.id.to_s }
      expect(compact_row[:account]).to eq owner.account_id.to_s
      expect(compact_row.dig(:fedibird_external, :presentation)).to eq expected

      get '/api/v1/bookmarks', headers: owner_headers
      expect(body_as_json.find { |row| row[:id] == status.id.to_s }.dig(:fedibird_external, :presentation)).to eq expected

      get '/api/v1/favourites', headers: owner_headers
      expect(body_as_json.find { |row| row[:id] == status.id.to_s }.dig(:fedibird_external, :presentation)).to eq expected

      expect(presentation_for(owner_headers, status)).to eq expected
    end

    it 'matches the owner-scoped streaming render and refuses the other user' do
      rendered = ExternalBridge::Streaming::StatusRenderer.render(status, owner)

      expect(rendered[:fedibird_external][:presentation]).to eq expected
      expect(rendered[:account].object.id).to eq owner.account_id
      expect(ExternalBridge::Streaming::StatusRenderer.render(status, roommate)).to be_nil
    end
  end

  describe 'query budget' do
    let(:projections) do
      Array.new(20) do |index|
        row = external_project_for(owner, body: "bulk article #{index}")
        attach_actor!(row, native_id: row[:source].canonical_key)
        save_route(owner, row[:subscription])
        row
      end
    end

    before do
      enable_external_bridge_feeds!(owner)
      projections
      Array.new(20) { |index| Fabricate(:status, account: owner.account, visibility: :public, text: "ordinary #{index}") }.each do |ordinary|
        redis.zadd(FeedManager.instance.key(:home, owner.account_id), [[ordinary.id, ordinary.id]])
      end
    end

    def assert_flat_reads(queries)
      %w(external_status_projections external_resources external_sources external_actors).each do |table|
        expect(table_reads(queries, table)).to be <= 6, "#{table} read #{table_reads(queries, table)} times for a 40 row page:\n#{queries.grep(/from "#{table}"/).first(5).join("\n")}"
      end
    end

    it 'reads the source tables once per page on home, not once per status' do
      queries = capture_sql { get '/api/v1/timelines/home', params: { limit: 40 }, headers: owner_headers }

      expect(response).to have_http_status(200)
      expect(body_as_json.count { |row| row[:fedibird_external] }).to eq 20
      expect(body_as_json.filter_map { |row| row.dig(:fedibird_external, :presentation, :name) }.uniq).to eq ['Public feed']
      assert_flat_reads(queries)
    end

    it 'reads the source tables once per page on compact home' do
      queries = capture_sql { get '/api/v1/timelines/home', params: { limit: 40, compact: true }, headers: owner_headers }

      expect(response).to have_http_status(200)
      expect(body_as_json[:statuses].count { |row| row[:fedibird_external] }).to eq 20
      assert_flat_reads(queries)
    end

    it 'reads the source tables once per page on bookmarks and favourites' do
      projections.each do |row|
        Bookmark.create!(account: owner.account, status: row[:status])
        Favourite.create!(account: owner.account, status: row[:status])
      end

      %w(/api/v1/bookmarks /api/v1/favourites).each do |path|
        queries = capture_sql { get path, params: { limit: 40 }, headers: owner_headers }

        expect(response).to have_http_status(200)
        expect(body_as_json.count { |row| row.dig(:fedibird_external, :presentation) }).to eq 20
        assert_flat_reads(queries)
      end
    end
  end
end

# rubocop:enable Metrics/BlockLength
