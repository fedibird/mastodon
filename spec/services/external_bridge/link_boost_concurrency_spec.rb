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

  it 'orders every visible flip once under simultaneous boosts and undos' do
    bundle = prepare_world
    allow(RemovalWorker).to receive(:perform_async)
    user = bundle[:user]

    outcome = run_together(8) { |index| index.odd? ? unboost(bundle) : boost(bundle) }
    outcome2 = run_together(6) { |index| index.even? ? unboost(bundle) : boost(bundle) }

    # status_stats is built on first use, so two threads that count the same
    # note can race on its unique index. That is the ordinary counter race.
    tolerated = lambda do |error|
      (error.is_a?(ExternalBridge::Error) && error.code == 'reference_conflict') ||
        (error.is_a?(ActiveRecord::RecordNotUnique) && error.message.include?('index_status_stats_on_status_id'))
    end
    unexpected = (outcome[:errors] + outcome2[:errors]).reject(&tolerated)
    expect(unexpected).to be_empty
    rows = ExternalProjectionLinkBoost.where(user_id: user.id)
    state = ExternalProjectionLinkBoostState.find_by!(user_id: user.id, projection_status_id: bundle[:world][:status].id)
    expect(rows.where(state: 'active').count).to be <= 1
    expect(state.revision).to eq(rows.count + rows.where(state: 'undone').count)
    expect(state.reblogged).to eq(rows.where(state: 'active').exists?)
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

  def pending_boost(bundle)
    result = nil
    Sidekiq::Testing.fake! do
      result = boost(bundle)
      ExternalBridge::LinkReferencePublishWorker.drain
      ExternalBridge::LinkBoostAnnounceWorker.clear
    end
    Sidekiq::Testing.inline!
    [result, ExternalProjectionLinkBoost.find_by!(user_id: bundle[:user].id)]
  end

  def record_distribution
    sent = Queue.new
    allow(ActivityPub::DistributionWorker).to receive(:perform_async) do |id, *|
      sent << id
      'jid'
    end
    sent
  end

  def drain(queue)
    items = []
    items << queue.pop until queue.empty?
    items
  end

  # Holds the policy row the way Policy.revoke! and friends do, applies the
  # change, and commits it only after the announce thread is waiting.
  def announce_behind_policy_change(bundle, row)
    holder = ActiveRecord::Base.connection_pool.checkout
    outcome = nil
    error = nil
    thread = nil
    begin
      holder.begin_db_transaction
      holder.select_value("SELECT id FROM external_link_share_policies WHERE user_id = #{bundle[:user].id.to_i} FOR UPDATE")
      yield holder
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          outcome = ExternalBridge::LinkSharing::BoostAnnounce.call(row.id)
        end
      rescue StandardError => e
        error = e
      ensure
        release_thread_redis!
      end
      sleep 0.4
      expect(thread).to be_alive
      holder.commit_db_transaction
      thread.join
    ensure
      holder.rollback_db_transaction if holder.transaction_open?
      ActiveRecord::Base.connection_pool.checkin(holder)
      thread&.join
    end
    raise error if error

    outcome
  end

  it 'sends nothing when a revocation committed before the delivery read the policy' do
    bundle = prepare_world
    result, row = pending_boost(bundle)
    sent = record_distribution

    outcome = announce_behind_policy_change(bundle, row) do |holder|
      holder.execute("UPDATE external_link_share_policies SET enabled = FALSE, revision = revision + 1, updated_at = NOW() WHERE user_id = #{bundle[:user].id.to_i}")
    end

    expect(outcome).to eq(:closed)
    expect(drain(sent)).not_to include(result.wrapper.id)
    expect(row.reload.state).to eq('undone')
    expect(row.ended_reason).to eq('consent_withdrawn')
    expect(row.announced_at).to be_nil
  ensure
    cleanup!(bundle)
  end

  it 'sends nothing after a scope change, or a revoke and a new grant, that committed first' do
    changes = {
      'scope change' => ->(holder, id) { holder.execute("UPDATE external_link_share_policies SET visibility = 'unlisted', revision = revision + 1 WHERE user_id = #{id}") },
      'revoke and grant' => ->(holder, id) { holder.execute("UPDATE external_link_share_policies SET enabled = TRUE, revision = revision + 2 WHERE user_id = #{id}") },
    }
    changes.each do |label, change|
      bundle = prepare_world
      begin
        result, row = pending_boost(bundle)
        sent = record_distribution

        outcome = announce_behind_policy_change(bundle, row) { |holder| change.call(holder, bundle[:user].id.to_i) }

        expect(outcome).to eq(:closed), label
        expect(drain(sent)).not_to include(result.wrapper.id), label
        expect(row.reload.announce_enqueued_at).to be_nil, label
      ensure
        cleanup!(bundle)
      end
    end
  end

  it 'lets an Announce that was accepted first stand, and ends it only by Undo' do
    bundle = prepare_world
    user = bundle[:user]
    result, row = pending_boost(bundle)
    sent = record_distribution
    removals = Queue.new
    allow(RemovalWorker).to receive(:perform_async) { |id, *| removals << id }
    revoker = nil
    handler = lambda do |*args|
      next unless args.last[:name] == :announce_after_enqueue

      revoker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ExternalBridge::LinkSharing::Policy.revoke!(user: User.find(user.id))
        end
      ensure
        release_thread_redis!
      end
      sleep 0.4
      expect(revoker).to be_alive
    end

    outcome = ActiveSupport::Notifications.subscribed(handler, ExternalBridge::LinkSharing::Checkpoints::EVENT) do
      ExternalBridge::LinkSharing::BoostAnnounce.call(row.id)
    end
    revoker.join

    expect(outcome).to eq(:announced)
    expect(drain(sent)).to eq([result.wrapper.id])
    row.reload
    expect(row.state).to eq('active')
    expect(row.announced_at).to be_present
    expect(row.announce_enqueued_at).to be_present
    expect(ExternalLinkSharePolicy.find_by(user_id: user.id).enabled).to be(false)
    expect(ExternalBridge::LinkSharing::BoostAnnounce.call(row.id)).to eq(:announced)
    expect(drain(sent)).to be_empty

    unboost(bundle)
    expect(drain(removals)).to eq([result.wrapper.id])
  ensure
    revoker&.join
    cleanup!(bundle)
  end

  it 'never announces after the user undid it, and always sends the Undo for an accepted job' do
    3.times do
      bundle = prepare_world
      begin
        result, row = pending_boost(bundle)
        sent = record_distribution
        removals = Queue.new
        allow(RemovalWorker).to receive(:perform_async) { |id, *| removals << id }

        outcome = run_together(2) { |index| index.zero? ? ExternalBridge::LinkSharing::BoostAnnounce.call(row.id) : unboost(bundle).ended }

        expect(outcome[:errors]).to be_empty
        accepted = drain(sent).include?(result.wrapper.id)
        undone = drain(removals).include?(result.wrapper.id)
        row.reload
        expect(row.state).to eq('undone')
        expect(row.ended_reason).to eq('user_undo')
        # The intent is committed before the enqueue, so an Undo that wins in
        # between is sent for a job that was never accepted. That is harmless.
        expect(undone).to be(true) if accepted
        expect(row.announce_enqueued_at.present?).to eq(accepted)
        expect(ExternalBridge::LinkSharing::BoostAnnounce.call(row.id)).to eq(:ended)
        expect(drain(sent)).to be_empty
      ensure
        cleanup!(bundle)
      end
    end
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
