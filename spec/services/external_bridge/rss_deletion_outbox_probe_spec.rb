# frozen_string_literal: true
# rubocop:disable Metrics/BlockLength, Metrics/ParameterLists

# Not part of the default run. Measure the capped effect-row outbox:
#   RSS_DELETION_OUTBOX_PROBE=1 RSS_DELETION_OUTBOX_PROBE_COUNT=20000 \
#     bundle exec rspec spec/services/external_bridge/rss_deletion_outbox_probe_spec.rb
require 'rails_helper'

describe 'ExternalBridge RSS deletion outbox probe', if: ENV['RSS_DELETION_OUTBOX_PROBE'].present?, type: :model do
  self.use_transactional_tests = false

  def relation_bytes(name)
    ActiveRecord::Base.connection.select_value("SELECT pg_total_relation_size(#{ActiveRecord::Base.connection.quote(name)})").to_i
  end

  def insert_slice(source, subscription, user, nonce, offset, size)
    now = Time.current
    resources = ExternalResource.insert_all(
      Array.new(size) do |index|
        n = offset + index
        {
          external_source_id: source.id,
          protocol: 'rss',
          canonical_key: "probe:#{nonce}:#{n}",
          title: 't',
          body: 'b',
          canonical_url: "https://example.com/probe/#{nonce}/#{n}",
          revision: '1',
          published_at: now,
          created_at: now,
          updated_at: now,
        }
      end,
      returning: %w(id)
    ).rows.flatten
    statuses = Status.insert_all(
      Array.new(size) do
        {
          account_id: user.account_id,
          text: 'x',
          visibility: Status.visibilities[:external],
          searchability: Status.searchabilities[:personal],
          external_projection: true,
          local: true,
          reply: false,
          created_at: now,
          updated_at: now,
        }
      end,
      returning: %w(id)
    ).rows.flatten
    ExternalStatusProjection.insert_all(
      resources.zip(statuses).map do |resource_id, status_id|
        {
          user_id: user.id,
          account_id: user.account_id,
          external_source_id: source.id,
          external_subscription_id: subscription.id,
          external_resource_id: resource_id,
          status_id: status_id,
          created_at: now,
          updated_at: now,
        }
      end
    )
  end

  it 'stops at the effect-row cap when stream enqueue is refused, then can finish' do
    count = Integer(ENV.fetch('RSS_DELETION_OUTBOX_PROBE_COUNT', '20000'))
    user = Fabricate(:user)
    nonce = SecureRandom.hex(4)
    source = ExternalSource.create!(
      protocol: 'rss', canonical_key: "https://feeds.example/probe-#{nonce}.xml",
      title: 'Probe', site_url: 'https://example.com', fetched_at: Time.current, checked_at: Time.current
    )
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    setup_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    offset = 0
    while offset < count
      insert_slice(source, subscription, user, nonce, offset, [2_000, count - offset].min)
      offset += 2_000
    end
    setup_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - setup_started
    subscription.update!(state: 'deleting')
    deletion = ExternalSubscriptionDeletion.create!(
      user: user,
      external_subscription_id: subscription.id,
      external_source_id: source.id,
      state: 'queued',
      route_targets: [{ 'type' => 'home' }],
      requested_at: Time.current,
      next_run_at: Time.current
    )
    ExternalBridge::StreamDeleteWorker.define_singleton_method(:perform_async) { |*| nil }
    refused_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    refused = ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(deletion.id)
    refused_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - refused_started
    deletion.reload
    open_rows = ExternalSubscriptionDeletionEffect.where(external_subscription_deletion_id: deletion.id).count
    payload = ActiveRecord::Base.connection.select_one(<<~SQL.squish)
      SELECT count(*) AS rows,
             coalesce(avg(pg_column_size(effects)), 0) AS avg_row_bytes,
             coalesce(sum(pg_column_size(effects)), 0) AS payload_bytes
      FROM external_subscription_deletion_effects effects
      WHERE external_subscription_deletion_id = #{deletion.id.to_i}
    SQL
    deletion_bytes = ActiveRecord::Base.connection.select_value(
      "SELECT pg_column_size(deletions) FROM external_subscription_deletions deletions WHERE id = #{deletion.id.to_i}"
    ).to_i

    warn format(
      'PROBE count=%d setup_s=%.2f refused_outcome=%s refused_s=%.2f deleted=%d remaining=%d open_rows=%d avg_row_bytes=%d payload_bytes=%d relation_bytes=%d deletion_row_bytes=%d state=%s',
      count, setup_seconds, refused, refused_seconds, deletion.deleted_count,
      ExternalStatusProjection.where(external_subscription_id: subscription.id).count,
      open_rows, payload['avg_row_bytes'].to_i, payload['payload_bytes'].to_i,
      relation_bytes('external_subscription_deletion_effects'), deletion_bytes, deletion.state
    )
    expect(refused).to eq :effects_pending
    expect(open_rows).to be <= (ExternalBridge::RSS::SubscriptionDeletionRunner::EFFECTS_CAP + ExternalBridge::RSS::SubscriptionDeletionRunner.batch_size)
    expect(open_rows).to be >= ExternalBridge::RSS::SubscriptionDeletionRunner::EFFECTS_CAP
    expect(deletion.deleted_count).to be < count
    expect(deletion).to be_running

    ExternalBridge::StreamDeleteWorker.define_singleton_method(:perform_async) { |*| 'jid' }
    finish_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcome = nil
    loop do
      outcome = ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(deletion.id)
      break if outcome == :completed || (Process.clock_gettime(Process::CLOCK_MONOTONIC) - finish_started) > 900
    end
    finish_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - finish_started
    warn format(
      'PROBE count=%d finish_outcome=%s finish_s=%.2f deleted=%d open_rows=%d',
      count, outcome, finish_seconds, deletion.reload.deleted_count,
      ExternalSubscriptionDeletionEffect.where(external_subscription_deletion_id: deletion.id).count
    )
    expect(outcome).to eq :completed
    expect(ExternalStatusProjection.where(external_subscription_id: subscription.id)).to be_empty
  ensure
    if defined?(user) && user&.persisted?
      ExternalSubscriptionDeletionEffect.where(external_subscription_deletion_id: ExternalSubscriptionDeletion.where(user_id: user.id).select(:id)).delete_all
      ExternalSubscriptionDeletion.where(user_id: user.id).delete_all
      ExternalStatusProjection.where(user_id: user.id).delete_all
      ActiveRecord::Base.connection.execute("SET fedibird.projection_status_delete = 'on'")
      Status.unscoped.where(account_id: user.account_id, external_projection: true).delete_all
      ActiveRecord::Base.connection.execute("SET fedibird.projection_status_delete = 'off'")
      if defined?(source) && source
        ExternalResource.where(external_source_id: source.id).delete_all
        ExternalSubscription.where(external_source_id: source.id).delete_all
        source.delete
      end
      user.destroy
    end
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/ParameterLists
