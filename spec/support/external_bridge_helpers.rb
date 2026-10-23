# frozen_string_literal: true

module ExternalBridgeHelpers
  def enable_external_bridge_rss!(*users)
    Setting.external_bridge_rss = true
    permit_external_bridge_rss_testers!(*users)
  end

  def enable_external_bridge_feeds!(*users)
    Setting.external_bridge_feeds = true
    permit_external_bridge_feeds_testers!(*users)
  end

  def permit_external_bridge_feeds_testers!(*users)
    ids = ExternalBridge::Feeds::Feature.tester_ids
    ids |= users.flatten.compact.map { |user| user.id.to_i }
    Setting.external_bridge_feeds_testers = ids.join(',')
  end

  def permit_external_bridge_rss_testers!(*users)
    ids = ExternalBridge::Feature.tester_ids
    ids |= users.flatten.compact.map { |user| user.id.to_i }
    Setting.external_bridge_rss_testers = ids.join(',')
  end

  def share_account_user(account)
    Fabricate(:user, account: account, email: "share-#{SecureRandom.hex(6)}@example.com")
  end

  def project_for(user, body: 'Secret article body', url: "https://feeds.example/#{SecureRandom.hex(4)}.xml")
    source = ExternalSource.create!(
      protocol: 'rss',
      canonical_key: url,
      title: 'Public feed',
      site_url: 'https://example.com',
      etag: 'W/"public"',
      fetched_at: Time.current,
      checked_at: Time.current
    )
    resource = ExternalResource.create!(
      external_source: source,
      protocol: 'rss',
      canonical_key: "feed:#{url}\nitem:guid-1",
      title: 'Imported title',
      body: body,
      canonical_url: 'https://example.com/posts/1',
      byline: 'Ada',
      revision: 'rev-1',
      published_at: Time.utc(2020, 1, 2, 3, 4, 5)
    )
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    status, marker = ExternalBridge::ProjectionWriter.new.create!(
      user: user,
      subscription: subscription,
      resource: resource,
      text: body
    )
    { status: status, marker: marker, resource: resource, source: source, subscription: subscription }
  end

  def external_project_for(user, body: 'External only article', url: "https://feeds.example/#{SecureRandom.hex(4)}.xml", id: nil, source_deleted: false, visibility: :external, state: 'active')
    source = ExternalSource.create!(
      protocol: 'rss',
      canonical_key: url,
      title: 'Public feed',
      site_url: 'https://example.com',
      etag: 'W/"public"',
      fetched_at: Time.current,
      checked_at: Time.current
    )
    resource = ExternalResource.create!(
      external_source: source,
      protocol: 'rss',
      canonical_key: "feed:#{url}\nitem:guid-external",
      title: 'External title',
      body: body,
      canonical_url: 'https://example.com/posts/external',
      byline: 'Ada',
      revision: 'rev-external',
      published_at: Time.utc(2020, 1, 2, 3, 4, 5)
    )
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: state)
    status = nil
    marker = nil
    ApplicationRecord.transaction do
      attributes = {
        account: user.account,
        text: body,
        visibility: visibility,
        searchability: :personal,
        uri: nil,
        external_projection: true,
        local: true,
        reply: false,
        sensitive: false,
      }
      attributes[:id] = id if id
      status = Status.create!(attributes)
      marker = ExternalStatusProjection.create!(
        user_id: user.id,
        account_id: user.account_id,
        external_source_id: subscription.external_source_id,
        external_subscription_id: subscription.id,
        external_resource_id: resource.id,
        status_id: status.id,
        last_seen_revision: resource.revision,
        source_deleted: source_deleted
      )
    end
    { status: status, marker: marker, resource: resource, source: source, subscription: subscription }
  end

  def auth_headers_for(user, scopes = 'read:statuses write:statuses read:favourites write:favourites read:bookmarks write:bookmarks')
    token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes)
    { 'Authorization' => "Bearer #{token.token}", 'Accept' => 'application/json' }
  end

  def rss_document(items)
    <<~XML
      <?xml version="1.0"?>
      <rss version="2.0">
        <channel>
          <title>Example feed</title>
          <link>https://example.com</link>
          #{items}
        </channel>
      </rss>
    XML
  end

  # Constraint errors abort the Rails connection inside transactional specs.
  # Catch them in PostgreSQL so the example can still see the unchanged rows.
  def expect_database_rejection(sql)
    ActiveRecord::Base.connection.execute(<<~SQL)
      DO $do$
      BEGIN
        #{sql};
        RAISE EXCEPTION 'statement succeeded';
      EXCEPTION
        WHEN check_violation OR foreign_key_violation THEN
          NULL;
      END
      $do$;
    SQL
  end

  def rss_item(guid:, title: 'Hello', link: 'https://example.com/hello', body: 'Article body', date: 'Thu, 02 Jan 2020 03:04:05 GMT')
    <<~XML
      <item>
        <title>#{title}</title>
        <guid>#{guid}</guid>
        <link>#{link}</link>
        <description>#{body}</description>
        <pubDate>#{date}</pubDate>
        <author>Ada</author>
      </item>
    XML
  end
end

RSpec.configure do |config|
  config.include ExternalBridgeHelpers
  config.after { ExternalBridge::Viewer.reset }
end
