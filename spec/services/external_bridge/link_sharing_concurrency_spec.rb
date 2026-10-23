# frozen_string_literal: true

require 'rails_helper'

# Two connections have to commit. The examples stay in one file so the lock order is visible together.
# rubocop:disable Metrics/BlockLength

class ExternalBridgeLinkSharingBarrier
  def initialize(count)
    @remaining = count
    @mutex = Mutex.new
    @condition = ConditionVariable.new
  end

  def wait
    @mutex.synchronize do
      @remaining -= 1
      if @remaining.positive?
        @condition.wait(@mutex)
      else
        @condition.broadcast
      end
    end
  end
end

describe 'ExternalBridge link sharing concurrency', type: :model do
  # Row locks only block other connections. These examples commit.
  self.use_transactional_tests = false

  def release_thread_redis!
    RedisConfiguration.pool.checkin
  rescue StandardError
    nil
  ensure
    Thread.current[:redis] = nil
  end

  def canonical_for(url)
    ExternalBridge::RSS::CanonicalURL.normalize!(url)
  end

  def prepare_world
    user = Fabricate(:user)
    url = "https://example.com/posts/#{SecureRandom.hex(6)}"
    world = external_project_for(user)
    world[:resource].update!(canonical_url: url)
    world[:source].update!(title: 'Safe Feed Title')
    enable_external_bridge_link_sharing!(user)
    policy = ExternalBridge::LinkSharing::Policy.grant!(user: user, visibility: 'public')
    { user: user, world: world, url: url, policy: policy }
  end

  def cleanup!(bundle)
    return if bundle.nil?

    user = bundle[:user]
    reference_ids = ExternalProjectionLinkReference.where(user_id: user.id).pluck(:reference_status_id)
    ExternalProjectionLinkReference.where(user_id: user.id).delete_all
    Status.unscoped.where(id: reference_ids.compact).delete_all
    ExternalLinkSharePolicy.where(user_id: user.id).delete_all
    subscription_ids = ExternalSubscription.where(user_id: user.id).pluck(:id)
    source_ids = ExternalSubscription.where(user_id: user.id).pluck(:external_source_id)
    subscription_ids.each do |subscription_id|
      subscription = ExternalSubscription.find_by(id: subscription_id)
      ExternalBridge::ProjectionPurge.purge_subscription!(subscription) if subscription
    end
    ExternalSubscription.where(user_id: user.id).delete_all
    ExternalResource.where(external_source_id: source_ids).delete_all
    ExternalSource.where(id: source_ids).delete_all
    account = user.account
    user.destroy!
    account&.destroy!
  ensure
    Setting.external_bridge_link_sharing = false
    Setting.external_bridge_link_sharing_testers = ''
    Rails.cache.clear
  end

  before do
    allow(LinkCrawlWorker).to receive(:perform_async)
    stub_request(:any, %r{\Ahttps://example\.com/}).to_return(
      status: 200,
      body: '<!DOCTYPE html><html><head><title>Allowed Page</title></head><body></body></html>',
      headers: { 'Content-Type' => 'text/html' }
    )
  end

  it 'creates one reference when two ensures run together' do
    bundle = prepare_world
    user = bundle[:user]
    marker_id = bundle[:world][:marker].id
    results = Queue.new
    errors = Queue.new
    barrier = ExternalBridgeLinkSharingBarrier.new(2)
    threads = Array.new(2) do
      Thread.new do
        barrier.wait
        ActiveRecord::Base.connection_pool.with_connection do
          result = ExternalBridge::LinkSharing::EnsureReference.call(
            user: User.find(user.id),
            projection: ExternalStatusProjection.find(marker_id),
            scope: 'public'
          )
          results << result.status.id
        end
      rescue StandardError => e
        errors << e
      ensure
        release_thread_redis!
      end
    end
    threads.each(&:join)
    drained = []
    drained << errors.pop until errors.empty?
    expect(drained).to be_empty
    ids = 2.times.map { results.pop }
    expect(ids.uniq.size).to eq(1)
    expect(ExternalProjectionLinkReference.where(user_id: user.id, state: 'active').count).to eq(1)
    expect(Status.where(id: ids.first).count).to eq(1)
  ensure
    cleanup!(bundle)
  end

  it 'sees a revocation that committed while generation waited on the policy lock' do
    bundle = prepare_world
    user = bundle[:user]
    holder = ActiveRecord::Base.connection_pool.checkout
    error = nil
    thread = nil
    begin
      holder.begin_db_transaction
      holder.select_value("SELECT id FROM external_link_share_policies WHERE user_id = #{user.id.to_i} FOR UPDATE")
      holder.execute("UPDATE external_link_share_policies SET enabled = FALSE, revision = revision + 1, updated_at = NOW() WHERE user_id = #{user.id.to_i}")
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ExternalBridge::LinkSharing::EnsureReference.call(
            user: User.find(user.id),
            projection: ExternalStatusProjection.find(bundle[:world][:marker].id),
            scope: 'public'
          )
        end
      rescue StandardError => e
        error = e
      ensure
        release_thread_redis!
      end
      sleep 0.4
      holder.commit_db_transaction
      thread.join
      expect(error).to be_a(ExternalBridge::Error)
      expect(error.code).to eq('consent_required')
      expect(ExternalProjectionLinkReference.where(user_id: user.id)).to be_empty
      expect(Status.where(account_id: user.account_id, external_projection: [false, nil]).count).to eq(0)
    ensure
      holder.rollback_db_transaction if holder.transaction_open?
      ActiveRecord::Base.connection_pool.checkin(holder)
      thread&.join
    end
  ensure
    cleanup!(bundle)
  end

  it 'sees a visibility change that committed while generation waited on the policy lock' do
    bundle = prepare_world
    user = bundle[:user]
    holder = ActiveRecord::Base.connection_pool.checkout
    error = nil
    thread = nil
    begin
      holder.begin_db_transaction
      holder.select_value("SELECT id FROM external_link_share_policies WHERE user_id = #{user.id.to_i} FOR UPDATE")
      holder.execute(<<~SQL)
        UPDATE external_link_share_policies
           SET visibility = 'unlisted', revision = revision + 1, updated_at = NOW()
         WHERE user_id = #{user.id.to_i}
      SQL
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ExternalBridge::LinkSharing::EnsureReference.call(
            user: User.find(user.id),
            projection: ExternalStatusProjection.find(bundle[:world][:marker].id),
            scope: 'public'
          )
        end
      rescue StandardError => e
        error = e
      ensure
        release_thread_redis!
      end
      sleep 0.4
      holder.commit_db_transaction
      thread.join
      expect(error).to be_a(ExternalBridge::Error)
      expect(error.code).to eq('scope_rejected')
      expect(ExternalProjectionLinkReference.where(user_id: user.id)).to be_empty
    ensure
      holder.rollback_db_transaction if holder.transaction_open?
      ActiveRecord::Base.connection_pool.checkin(holder)
      thread&.join
    end
  ensure
    cleanup!(bundle)
  end

  it 'rolls its own status back and returns the row that won the unique insert' do
    bundle = prepare_world
    user = bundle[:user]
    marker = bundle[:world][:marker]
    url = canonical_for(bundle[:url])
    captured = nil
    winner = nil
    subscriber = ActiveSupport::Notifications.subscribe(ExternalBridge::LinkSharing::Checkpoints::EVENT) do |*args|
      payload = args.last
      next unless payload[:name] == :before_mapping_insert

      captured = payload[:extra]
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          winner = Status.create!(
            account_id: user.account_id,
            text: "Safe Feed Title\nRSS\n#{url}",
            visibility: :public,
            searchability: :public,
            local: true,
            reply: false
          )
          ExternalProjectionLinkReference.create!(
            user_id: user.id,
            account_id: user.account_id,
            external_status_projection_id: marker.id,
            projection_status_id: marker.status_id,
            reference_status_id: winner.id,
            visibility: 'public',
            canonical_url: url,
            policy_revision: bundle[:policy].revision,
            state: 'active'
          )
        end
      ensure
        release_thread_redis!
      end.join
    end

    result = ExternalBridge::LinkSharing::EnsureReference.call(user: user, projection: marker, scope: 'public')
    expect(winner).to be_present
    expect(result.status.id).to eq(winner.id)
    expect(Status.find_by(id: captured)).to be_nil
    expect(ExternalProjectionLinkReference.where(user_id: user.id, state: 'active').count).to eq(1)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    cleanup!(bundle)
  end
end

# rubocop:enable Metrics/BlockLength
