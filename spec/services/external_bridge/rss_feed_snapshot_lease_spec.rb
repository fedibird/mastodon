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
