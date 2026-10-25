# frozen_string_literal: true

# Several connections have to commit. One file keeps the lock order visible.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

describe 'ExternalBridge asynchronous RSS unsubscribe concurrency', type: :model do
  self.use_transactional_tests = false

  around do |example|
    Sidekiq::Testing.fake! { example.run }
  end

  before do
    allow(LinkCrawlWorker).to receive(:perform_async)
    RedisConfiguration.establish_pool(RedisConfiguration.pool_size)
    Thread.current[:redis] = nil
    ExternalBridge::RSS::SubscriptionDeletionWorker.clear
  end

  after do
    cleanup!
    Setting.external_bridge_rss = false
    Setting.external_bridge_rss_testers = ''
    Rails.cache.clear
  end

  def release_thread_redis!
    RedisConfiguration.pool.checkin
  rescue StandardError
    nil
  ensure
    Thread.current[:redis] = nil
  end

  def build_world(count = 1)
    @user = Fabricate(:user)
    enable_external_bridge_rss!(@user)
    @world = project_for(@user)
    (count - 1).times { add_projection(@world, @user) }
    @world
  end

  def add_projection(world, user)
    resource = ExternalResource.create!(
      external_source: world[:source],
      protocol: 'rss',
      canonical_key: "feed:#{world[:source].canonical_key}\nitem:#{SecureRandom.hex(6)}",
      title: 'Another',
      body: 'Another body',
      canonical_url: "https://example.com/posts/#{SecureRandom.hex(4)}",
      revision: 'rev-extra',
      published_at: Time.utc(2020, 1, 2, 3, 4, 5)
    )
    ExternalBridge::ProjectionWriter.new.create!(user: user, subscription: world[:subscription], resource: resource, text: 'Another body')
    resource
  end

  def cleanup!
    return if @user.nil?

    source_ids = ExternalSubscription.where(user_id: @user.id).pluck(:external_source_id) | [@world&.dig(:source)&.id].compact
    ExternalBridge::DeleteUser.call(User.find(@user.id)) if User.exists?(@user.id)
    ExternalResource.where(external_source_id: source_ids).delete_all
    ExternalSource.where(id: source_ids).delete_all
    Account.where(id: @user.account_id).destroy_all
  ensure
    @user = nil
  end

  def projections
    ExternalStatusProjection.where(external_subscription_id: @world[:subscription].id)
  end

  def in_thread(&block)
    Thread.new do
      Sidekiq::Testing.fake! do
        ActiveRecord::Base.connection_pool.with_connection(&block)
      end
    rescue StandardError => e
      Thread.current[:error] = e
      nil
    ensure
      release_thread_redis!
    end
  end

  def unsubscribe_as_user
    ExternalBridge::RSS::Subscribe.new.unsubscribe!(user: User.find(@user.id), subscription_id: @world[:subscription].id)
  end

  it 'lets a writer that holds the share lock commit before the fence, and the job then removes what it wrote' do
    build_world(1)
    entered = Queue.new
    release = Queue.new
    resource = ExternalResource.create!(
      external_source: @world[:source], protocol: 'rss',
      canonical_key: "feed:#{@world[:source].canonical_key}\nitem:in-flight", title: 'In flight', body: 'In flight body',
      canonical_url: 'https://example.com/posts/in-flight', revision: 'rev-1', published_at: Time.utc(2020, 1, 4)
    )
    allow(ExternalStatusProjection).to receive(:create!).and_wrap_original do |method, *args, **kwargs|
      entered << true
      release.pop
      method.call(*args, **kwargs)
    end

    writer = in_thread do
      ExternalBridge::ProjectionWriter.new.create!(
        user: User.find(@user.id), subscription: ExternalSubscription.find(@world[:subscription].id), resource: resource, text: 'In flight body'
      )
    end
    entered.pop
    accepted = in_thread { unsubscribe_as_user }
    begin
      sleep 0.6
      expect(accepted.alive?).to be true
      expect(ExternalSubscription.find(@world[:subscription].id).state).to eq 'active'
    ensure
      release << true
      writer.join
      accepted.join
    end

    expect(writer[:error]).to be_nil
    expect(accepted[:error]).to be_nil
    expect(ExternalSubscription.find(@world[:subscription].id).state).to eq 'deleting'
    expect(projections.count).to eq 2
    deletion = ExternalSubscriptionDeletion.find_by!(external_subscription_id: @world[:subscription].id)

    ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(deletion.id)

    expect(deletion.reload).to be_completed
    expect(deletion.deleted_count).to eq 2
    expect(ExternalStatusProjection.where(external_resource_id: resource.id)).to be_empty
  end

  it 'refuses a writer that starts after the fence committed' do
    build_world(1)
    stale = ExternalSubscription.find(@world[:subscription].id)
    resource = ExternalResource.create!(
      external_source: @world[:source], protocol: 'rss',
      canonical_key: "feed:#{@world[:source].canonical_key}\nitem:too-late", title: 'Late', body: 'Late body',
      canonical_url: 'https://example.com/posts/late', revision: 'rev-1', published_at: Time.utc(2020, 1, 4)
    )
    unsubscribe_as_user
    statuses = Status.unscoped.count

    thread = in_thread do
      ExternalBridge::ProjectionWriter.new.create!(user: User.find(@user.id), subscription: stale, resource: resource, text: 'Late body')
    end
    thread.join

    expect(thread[:error]).to be_a(ExternalBridge::RSS::SubscriptionFence::Fenced)
    expect(Status.unscoped.count).to eq statuses
    expect(ExternalStatusProjection.where(external_resource_id: resource.id)).to be_empty
  end

  it 'lets an in-flight materialize that outlives the whole deletion write nothing and record nothing' do
    build_world(1)
    stale = ExternalSubscription.find(@world[:subscription].id)
    fresh = ExternalResource.create!(
      external_source: @world[:source], protocol: 'rss',
      canonical_key: "feed:#{@world[:source].canonical_key}\nitem:fetched", title: 'Fetched', body: 'Fetched body',
      canonical_url: 'https://example.com/posts/fetched', revision: 'rev-1', published_at: Time.utc(2020, 1, 4)
    )
    entered = Queue.new
    release = Queue.new
    allow_any_instance_of(ExternalBridge::RSS::Materialize).to receive(:suppressed?).and_wrap_original do |method, *args|
      entered << true
      release.pop
      method.call(*args)
    end

    materialize = in_thread do
      ExternalBridge::RSS::Materialize.new.call(subscription: stale, resources: [fresh])
    end
    entered.pop
    begin
      deletion = unsubscribe_as_user
      ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(deletion.id)
      expect(ExternalSubscription.exists?(@world[:subscription].id)).to be false
    ensure
      release << true
      materialize.join
    end

    expect(materialize[:error]).to be_nil
    expect(materialize.value.ran).to be false
    expect(ExternalStatusProjection.where(external_resource_id: fresh.id)).to be_empty
    expect(ExternalProjectionFailure.where(external_resource_id: fresh.id)).to be_empty
    expect(ExternalSubscriptionDeletion.find(deletion.id)).to be_completed
  end

  it 'returns one record and one job for requests that arrive together' do
    build_world(2)
    threads = Array.new(3) { in_thread { unsubscribe_as_user } }
    threads.each(&:join)

    expect(threads.map { |thread| thread[:error] }).to all(be_nil)
    expect(threads.map { |thread| thread.value.id }.uniq.size).to eq 1
    expect(ExternalSubscriptionDeletion.where(external_subscription_id: @world[:subscription].id).count).to eq 1
    expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1
  end

  it 'lets two workers take turns on one record without double counting' do
    build_world(45)
    deletion = unsubscribe_as_user
    stub_const('ExternalBridge::RSS::SubscriptionDeletionRunner::MAX_BATCHES', 1000)
    previous = ENV['EXTERNAL_RSS_DELETION_BATCH_SIZE']
    ENV['EXTERNAL_RSS_DELETION_BATCH_SIZE'] = '10'

    threads = Array.new(2) { in_thread { ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(deletion.id) } }
    threads.each(&:join)

    expect(threads.map { |thread| thread[:error] }).to all(be_nil)
    expect(threads.map(&:value)).to all(be_in([:completed, :gone, :failed]))
    deletion.reload
    expect(deletion).to be_completed
    expect(deletion.deleted_count).to eq 45
    expect(deletion.total_count).to eq 45
    expect(ExternalStatusProjection.where(external_source_id: @world[:source].id).count).to eq 0
    expect(ExternalSubscription.exists?(@world[:subscription].id)).to be false
  ensure
    ENV['EXTERNAL_RSS_DELETION_BATCH_SIZE'] = previous
  end

  it 'does not let a worker that was slow to finish delete the suppressions of a later subscription to the same source' do
    build_world(1)
    ExternalBridge::ProjectionPurge.purge_status_ids!(projections.pluck(:status_id))
    deletion = unsubscribe_as_user
    entered = Queue.new
    release = Queue.new
    subscriber = ActiveSupport::Notifications.subscribe('external_bridge.rss_deletion') do |*args|
      next unless args.last[:name] == :finish_after_read && Thread.current[:slow_finisher]

      entered << true
      release.pop
    end

    slow = in_thread do
      Thread.current[:slow_finisher] = true
      ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(deletion.id)
    end
    entered.pop
    begin
      expect(ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(deletion.id)).to eq :completed
      expect(ExternalSubscriptionDeletion.find(deletion.id)).to be_completed
      fresh = ExternalSubscription.create!(user: User.find(@user.id), external_source_id: @world[:source].id, state: 'active')
      suppression = ExternalProjectionSuppression.create!(user_id: @user.id, external_resource_id: @world[:resource].id)
    ensure
      release << true
      slow.join
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    expect(slow[:error]).to be_nil
    expect(slow.value).to eq :completed
    expect(ExternalProjectionSuppression.exists?(suppression.id)).to be true
    expect(ExternalSubscription.exists?(fresh.id)).to be true
    expect(ExternalSubscriptionDeletion.find(deletion.id)).to be_completed
  end
end

# rubocop:enable Metrics/BlockLength
