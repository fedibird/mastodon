# frozen_string_literal: true

require 'rails_helper'

# Two database connections have to commit. The example transaction would hide
# the successor's claim from the worker that still holds the old token.
RSpec.describe 'RSS snapshot lease fencing', type: :model do
  self.use_transactional_tests = false

  after do
    source_ids = ExternalSource.where('canonical_key LIKE ?', 'https://feeds.example/lease-%').pluck(:id)
    subscription_ids = ExternalSubscription.where(external_source_id: source_ids).pluck(:id)
    ExternalFeedCatchUp.where(external_subscription_id: subscription_ids).delete_all
    ExternalSubscription.where(id: subscription_ids).delete_all
    ExternalResource.where(external_source_id: source_ids).delete_all
    ExternalFeedSnapshot.where(external_source_id: source_ids).delete_all
    keys = ExternalSource.where(id: source_ids).pluck(:canonical_key)
    ExternalActor.where(native_id: keys).delete_all
    ExternalSource.where(id: source_ids).delete_all
    Setting.external_bridge_rss = false
    Setting.external_bridge_rss_testers = ''
  end

  it 'does not let the worker that lost the lease clear the successor after an exception' do
    source = ExternalSource.create!(protocol: 'rss', canonical_key: "https://feeds.example/lease-#{SecureRandom.hex(4)}.xml", title: 'Lease')
    snapshot = ExternalFeedSnapshot.create!(
      external_source: source, generation: 1, state: 'pending', body: '<rss/>', byte_size: 6, item_count: 2, next_index: 0, history_positions: []
    )
    stolen = nil
    expired = nil
    allow_any_instance_of(ExternalBridge::RSS::FeedSnapshot::Drain).to receive(:apply_batch!).and_wrap_original do |_method, row, token|
      expired = token
      in_connection do
        ExternalFeedSnapshot.find(row.id).update_columns(lease_expires_at: 1.minute.ago)
        stolen = ExternalFeedSnapshot.find(row.id).claim_lease!
      end
      raise 'boom'
    end

    expect(ExternalBridge::RSS::FeedSnapshot::Drain.new.advance!(source.id)).to eq(:ok)

    snapshot.reload
    expect(stolen).to be_present
    expect(stolen).not_to eq(expired)
    expect(snapshot.lease_token).to eq(stolen)
    expect(snapshot.attempt_count).to eq(0)
    expect(snapshot.state).to eq('draining')
    expect(snapshot.note_attempt!('snapshot_failed', expired)).to be_nil
    expect(snapshot.fail!('snapshot_batch_limit', expired)).to be false
    expect(snapshot.finish!(expired)).to be false
    expect(snapshot.release_lease!(expired)).to eq(0)
    expect(snapshot.reload.lease_token).to eq(stolen)
    expect(snapshot.state).to eq('draining')
    expect(snapshot.attempt_count).to eq(0)
  end

  it 'does not let an expired catch-up worker advance the cursor or project' do
    user = Fabricate(:user)
    enable_external_bridge_rss!(user)
    source = ExternalSource.create!(protocol: 'rss', canonical_key: "https://feeds.example/lease-#{SecureRandom.hex(4)}.xml", title: 'Catch')
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    snapshot = ExternalFeedSnapshot.create!(
      external_source: source, generation: 3, state: 'complete', byte_size: 40, item_count: 1, next_index: 1,
      body: <<~XML,
        <?xml version="1.0"?><rss version="2.0"><channel><title>t</title><link>https://example.com</link>
        <item><title>T</title><guid>guid-x</guid><link>https://example.com/i/x</link><description>B</description><pubDate>Wed, 01 Jan 2020 00:00:00 +0000</pubDate></item>
        </channel></rss>
      XML
      created_at: 1.minute.from_now
    )
    row = ExternalFeedCatchUp.create!(
      external_subscription: subscription, external_feed_snapshot: snapshot, generation: 3, position: 0, state: 'pending'
    )
    stolen = nil
    allow_any_instance_of(ExternalBridge::RSS::FeedSnapshot::CatchUp).to receive(:before_catch_up_write!).and_wrap_original do |_method, caught|
      in_connection do
        ExternalFeedCatchUp.find(caught.id).update_columns(lease_expires_at: 1.minute.ago)
        stolen = ExternalFeedCatchUp.find(caught.id).claim!
      end
    end

    expect(ExternalBridge::RSS::FeedSnapshot::CatchUp.advance!(subscription.id)).to eq(:ok)

    row.reload
    expect(stolen).to be_present
    expect(row.lease_token).to eq(stolen)
    expect(row.position).to eq(0)
    expect(row.generation).to eq(3)
    expect(ExternalStatusProjection.where(user_id: user.id).count).to eq(0)
  end

  it 'lets only one of two connections pass the snapshot byte cap' do
    body = rss_document(rss_item(guid: 'guid-cap', title: 'Cap', link: 'https://example.com/i/cap'))
    extra = body.bytesize
    stub_const('ExternalBridge::RSS::Limits::SNAPSHOT_RETAINED_BODY_BYTES', ExternalFeedSnapshot.held_body_bytes + extra + 10)
    source_a = ExternalSource.create!(protocol: 'rss', canonical_key: "https://feeds.example/lease-cap-a-#{SecureRandom.hex(4)}.xml", title: 'Cap A')
    source_b = ExternalSource.create!(protocol: 'rss', canonical_key: "https://feeds.example/lease-cap-b-#{SecureRandom.hex(4)}.xml", title: 'Cap B')
    hold = Queue.new
    holding = Queue.new
    inserter, inserter_errors = start_locked_insert(source_a, body, hold, holding)
    capturer = nil
    capture_errors = []
    begin
      expect(holding.pop).to be true
      capturer = start_blocked_capture(source_b, body, capture_errors)
      expect(wait_for_capacity_waiter).to be true
      expect(capturer).to be_alive
      expect(ExternalFeedSnapshot.where(external_source_id: source_b.id)).to be_empty
      hold << true
      expect(inserter.join(15)).to eq(inserter)
      expect(capturer.join(15)).to eq(capturer)
    ensure
      hold << true
      inserter.join(15)
      capturer&.join(15)
    end

    expect(inserter_errors).to be_empty
    expect(capture_errors.first).to be_a(ExternalBridge::Error)
    expect(capture_errors.first.code).to eq('snapshot_capacity')
    expect(ExternalFeedSnapshot.where(external_source_id: source_a.id).where.not(body: nil).count).to eq(1)
    expect(ExternalFeedSnapshot.where(external_source_id: source_b.id)).to be_empty
    expect(source_b.reload.etag).to be_nil
  end

  def start_locked_insert(source, body, hold, holding)
    errors = []
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{ExternalBridge::RSS::Limits::SNAPSHOT_CAPACITY_LOCK})")
          holding << true
          hold.pop
          ExternalFeedSnapshot.create!(
            external_source: source, generation: 1, state: 'complete', body: body, byte_size: body.bytesize,
            item_count: 1, next_index: 1, completed_at: Time.current
          )
        end
      end
    rescue StandardError => e
      errors << e
      holding << false
    end
    [thread, errors]
  end

  def start_blocked_capture(source, body, errors)
    response = feed_response(source, body)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ExternalBridge::RSS::FeedSnapshot::Capture.new.call(response: response, canonical_key: source.canonical_key, source: source)
      end
    rescue StandardError => e
      errors << e
    end
  end

  def feed_response(source, body)
    ExternalBridge::RSS.const_get(:HttpClient)
    ExternalBridge::RSS::Response.new(
      code: 200, body: body, etag: 'W/"b"', last_modified: nil, final_url: source.canonical_key,
      content_type: 'application/rss+xml', content_length: body.bytesize
    )
  end

  def wait_for_capacity_waiter
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      waiting = ApplicationRecord.connection.select_value(<<~SQL.squish)
        SELECT COUNT(*) FROM pg_locks
        WHERE locktype = 'advisory' AND classid = 0 AND objid = #{ExternalBridge::RSS::Limits::SNAPSHOT_CAPACITY_LOCK}
          AND objsubid = 1 AND NOT granted
      SQL
      return true if waiting.to_i >= 1
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  def in_connection
    error = nil
    value = nil
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        value = yield
      end
    rescue StandardError => e
      error = e
    end
    thread.join
    raise error if error

    value
  end
end
