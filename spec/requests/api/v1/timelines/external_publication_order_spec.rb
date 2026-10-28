# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength

RSpec.describe 'External publication order on the home timeline' do
  # Clients that only send since_id learn about ids newer than their cursor.
  # A late external status keeps the original publication id, which is older
  # than a status the client has already seen, so that poll does not return
  # it. max_id / min_id paging of the loaded range still reaches it. This
  # server does not add an arrival cursor.

  def save_route(user, subscription)
    ExternalBridge::FeedRoutes::Update.new.call(
      user: user,
      subscription_id: subscription.id,
      home: true,
      list_ids: [],
      expected_revision: subscription.reload.feed_routes_revision
    )
  end

  def project!(user, published_at, title)
    source = ExternalSource.create!(
      protocol: 'rss',
      canonical_key: "https://feeds.example/#{SecureRandom.hex(6)}.xml",
      title: 'Example feed',
      site_url: 'https://example.test',
      fetched_at: Time.current,
      checked_at: Time.current
    )
    resource = ExternalResource.create!(
      external_source: source,
      protocol: 'rss',
      canonical_key: "feed:#{source.canonical_key}\nitem:#{title}",
      title: title,
      body: "Body #{title}",
      canonical_url: "https://example.test/#{title}",
      byline: 'Ada',
      revision: "rev-#{title}",
      published_at: published_at
    )
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    status, = ExternalBridge::ProjectionWriter.new.create!(user: user, subscription: subscription, resource: resource)
    save_route(user, subscription)
    status
  end

  def home(params = {})
    get '/api/v1/timelines/home', params: params, headers: headers
    expect(response).to have_http_status(200)
    body_as_json
  end

  let(:owner) { Fabricate(:user, account: Fabricate(:account, username: 'orderowner')) }
  let(:headers) { auth_headers_for(owner, 'read:statuses') }

  before do
    Setting.external_bridge_external_visibility = true
    enable_external_bridge_feeds!(owner)
  end

  after do
    Setting.external_bridge_external_visibility = false
    Setting.external_bridge_feeds = false
    Setting.external_bridge_feeds_testers = ''
  end

  it 'orders 11:00, 09:00, then 10:00 arrivals as 11:00, 10:00, 09:00 and keeps since_id exclusive' do
    eleven = project!(owner, Time.utc(2024, 3, 3, 11, 0, 0), 'eleven')
    nine = project!(owner, Time.utc(2024, 3, 3, 9, 0, 0), 'nine')
    ten = project!(owner, Time.utc(2024, 3, 3, 10, 0, 0), 'ten')

    rows = home
    expect(rows.map { |row| row[:id] }).to eq [eleven.id, ten.id, nine.id].map(&:to_s)
    expect(Time.iso8601(rows[0][:created_at]).to_i).to eq eleven.created_at.to_i
    expect(Time.iso8601(rows[1][:created_at]).to_i).to eq ten.created_at.to_i
    expect(Time.iso8601(rows[2][:created_at]).to_i).to eq nine.created_at.to_i
    expect(eleven.updated_at).to be > eleven.created_at
    expect(ten.updated_at).to be > ten.created_at

    expect(home(since_id: eleven.id)).to eq []
    expect(home(max_id: eleven.id).map { |row| row[:id] }).to eq [ten.id, nine.id].map(&:to_s)
    expect(home(min_id: nine.id).map { |row| row[:id] }).to eq [eleven.id, ten.id].map(&:to_s)
    expect(home(max_id: eleven.id, min_id: nine.id).map { |row| row[:id] }).to eq [ten.id.to_s]
  end
end
# rubocop:enable Metrics/BlockLength
