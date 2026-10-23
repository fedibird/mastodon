# frozen_string_literal: true

# Several connections have to commit. One file keeps the lock order visible.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

class ExternalBridgeLinkBoostBarrier
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

describe 'ExternalBridge link boost concurrency', type: :model do
  self.use_transactional_tests = false

  def release_thread_redis!
    RedisConfiguration.pool.checkin
  rescue StandardError
    nil
  ensure
    Thread.current[:redis] = nil
  end

  def prepare_world
    user = Fabricate(:user)
    url = "https://example.com/posts/#{SecureRandom.hex(6)}"
    world = external_project_for(user)
    world[:resource].update!(canonical_url: url)
    world[:source].update!(title: 'Safe Feed Title')
    enable_external_bridge_link_sharing!(user)
    ExternalBridge::LinkSharing::Policy.grant!(user: user, visibility: 'public')
    { user: user, world: world, url: url }
  end

  def cleanup!(bundle)
    return if bundle.nil?

    user = bundle[:user]
    reference_ids = ExternalProjectionLinkReference.where(user_id: user.id).pluck(:reference_status_id).compact
    Status.unscoped.where(reblog_of_id: reference_ids).delete_all
    ExternalProjectionLinkReference.where(user_id: user.id).delete_all
    Status.unscoped.where(id: reference_ids).delete_all
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

  def run_together(count)
    barrier = ExternalBridgeLinkBoostBarrier.new(count)
    results = Queue.new
    errors = Queue.new
    threads = Array.new(count) do |index|
      Thread.new do
        barrier.wait
        ActiveRecord::Base.connection_pool.with_connection { results << yield(index) }
      rescue StandardError => e
        errors << e
      ensure
        release_thread_redis!
      end
    end
    threads.each(&:join)
    drained = { results: [], errors: [] }
    drained[:results] << results.pop until results.empty?
    drained[:errors] << errors.pop until errors.empty?
    drained
  end

  def boost(bundle)
    ExternalBridge::LinkSharing::Boost.call(
      user: User.find(bundle[:user].id),
      status: Status.find(bundle[:world][:status].id)
    )
  end

  def unboost(bundle)
    ExternalBridge::LinkSharing::Unboost.call(
      user: User.find(bundle[:user].id),
      status: Status.find(bundle[:world][:status].id)
    )
  end

  before do
    allow(LinkCrawlWorker).to receive(:perform_async)
    allow(DistributionWorker).to receive(:perform_async)
    allow(PriorityDistributionWorker).to receive(:perform_async)
    # streaming_delivery_spec kills its subscriber thread without returning
    # the pooled Redis connection from subscribe mode, and any later thread
    # that draws it fails. These examples commit from several threads, so they
    # start from a fresh pool.
    RedisConfiguration.establish_pool(RedisConfiguration.pool_size)
    Thread.current[:redis] = nil
    stub_request(:any, %r{\Ahttps://example\.com/}).to_return(
      status: 200,
      body: '<html><head><title>x</title></head><body></body></html>',
      headers: { 'Content-Type' => 'text/html' }
    )
  end

  it 'creates one wrapper and one row for two simultaneous boosts' do
    bundle = prepare_world
    announces = Queue.new
    allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |id, *| announces << id }

    outcome = run_together(2) { boost(bundle).wrapper.id }

    expect(outcome[:errors]).to be_empty
    expect(outcome[:results].uniq.size).to eq(1)
    rows = ExternalProjectionLinkBoost.where(user_id: bundle[:user].id)
    expect(rows.count).to eq(1)
    expect(rows.first.state).to eq('active')
    reference_id = rows.first.reference_status_id
    expect(Status.where(reblog_of_id: reference_id).count).to eq(1)
    expect(ExternalProjectionLinkReference.where(user_id: bundle[:user].id).count).to eq(1)
    sent = []
    sent << announces.pop until announces.empty?
    expect(sent.count(outcome[:results].first)).to eq(1)
  ensure
    cleanup!(bundle)
  end

  it 'ends once and sends one Undo for two simultaneous undos' do
    bundle = prepare_world
    boost(bundle)
    removals = Queue.new
    allow(RemovalWorker).to receive(:perform_async) { |id, *| removals << id }

    outcome = run_together(2) { unboost(bundle).ended }

    expect(outcome[:errors]).to be_empty
    expect(outcome[:results].sort).to eq([0, 1])
    expect(ExternalProjectionLinkBoost.where(user_id: bundle[:user].id).pluck(:state)).to eq(['undone'])
    sent = []
    sent << removals.pop until removals.empty?
    expect(sent.size).to eq(1)
  ensure
    cleanup!(bundle)
  end

  it 'never leaves two live shares after boost, undo, and boost run together' do
    bundle = prepare_world
    boost(bundle)
    allow(RemovalWorker).to receive(:perform_async)

    outcome = run_together(4) do |index|
      index == 1 ? unboost(bundle) : boost(bundle)
    end

    unexpected = outcome[:errors].reject { |error| error.is_a?(ExternalBridge::Error) && %w(reference_conflict).include?(error.code) }
    expect(unexpected).to be_empty
    rows = ExternalProjectionLinkBoost.where(user_id: bundle[:user].id)
    expect(rows.where(state: 'active').count).to be <= 1
    reference_id = rows.first.reference_status_id
    live_wrappers = Status.where(reblog_of_id: reference_id, account_id: bundle[:user].account_id)
    expect(live_wrappers.count).to be >= rows.where(state: 'active').count
    expect(live_wrappers.count).to be <= 2
    expect(rows.pluck(:generation).uniq.size).to eq(rows.count)
  ensure
    cleanup!(bundle)
  end

  it 'closes the share at announce time when a revocation arrives while the boost holds the policy lock' do
    bundle = prepare_world
    user = bundle[:user]
    announced = Queue.new
    allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |id, *| announced << id }
    revoker = nil
    subscriber = lambda do |*args|
      payload = args.last
      next unless payload[:name] == :before_boost_create

      revoker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ExternalBridge::LinkSharing::Policy.revoke!(user: User.find(user.id))
        end
      ensure
        release_thread_redis!
      end
      sleep 0.4
    end

    result = nil
    Sidekiq::Testing.fake! do
      ActiveSupport::Notifications.subscribed(subscriber, ExternalBridge::LinkSharing::Checkpoints::EVENT) do
        result = boost(bundle)
      end
      revoker.join
      ExternalBridge::LinkReferencePublishWorker.drain
      ExternalBridge::LinkBoostAnnounceWorker.drain
    end
    Sidekiq::Testing.inline!

    row = ExternalProjectionLinkBoost.find_by!(user_id: user.id)
    expect(row.state).to eq('undone')
    expect(row.ended_reason).to eq('consent_withdrawn')
    published = []
    published << announced.pop until announced.empty?
    expect(published).not_to include(result.wrapper.id)
    expect(ExternalLinkSharePolicy.find_by(user_id: user.id).enabled).to be(false)
  ensure
    revoker&.join
    cleanup!(bundle)
  end

  it 'refuses a boost whose consent was revoked between ensure and the wrapper insert' do
    bundle = prepare_world
    user = bundle[:user]
    subscriber = lambda do |*args|
      payload = args.last
      next unless payload[:name] == :before_boost_lock

      ExternalBridge::LinkSharing::Policy.revoke!(user: User.find(user.id))
    end

    expect do
      ActiveSupport::Notifications.subscribed(subscriber, ExternalBridge::LinkSharing::Checkpoints::EVENT) { boost(bundle) }
    end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq('consent_required') }

    expect(ExternalProjectionLinkBoost.where(user_id: user.id)).to be_empty
    reference_id = ExternalProjectionLinkReference.find_by!(user_id: user.id).reference_status_id
    expect(Status.where(reblog_of_id: reference_id)).to be_empty
  ensure
    cleanup!(bundle)
  end

  it 'announces once for two simultaneous announce jobs' do
    bundle = prepare_world
    announces = Queue.new
    allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |id, *| announces << id }
    result = nil
    Sidekiq::Testing.fake! do
      result = boost(bundle)
      ExternalBridge::LinkReferencePublishWorker.drain
    end
    Sidekiq::Testing.inline!
    row = ExternalProjectionLinkBoost.find_by!(user_id: bundle[:user].id)
    announces.clear

    outcome = run_together(3) { ExternalBridge::LinkSharing::BoostAnnounce.call(row.id) }

    expect(outcome[:errors]).to be_empty
    sent = []
    sent << announces.pop until announces.empty?
    expect(sent).to eq([result.wrapper.id])
    expect(row.reload.announced_at).to be_present
  ensure
    cleanup!(bundle)
  end
end

# rubocop:enable Metrics/BlockLength
