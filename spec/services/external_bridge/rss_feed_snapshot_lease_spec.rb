# frozen_string_literal: true

require 'rails_helper'

# Two database connections have to commit. The example transaction would hide
# the successor's claim from the worker that still holds the old token.
RSpec.describe 'RSS snapshot lease fencing', type: :model do
  self.use_transactional_tests = false

  after do
    ExternalFeedSnapshot.where(external_source_id: ExternalSource.where('canonical_key LIKE ?', 'https://feeds.example/lease-%').select(:id)).delete_all
    ExternalSource.where('canonical_key LIKE ?', 'https://feeds.example/lease-%').delete_all
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
