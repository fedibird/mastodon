# frozen_string_literal: true

# Real connections and real commits: an E4 share and an accepted unsubscribe
# must be serialized through the subscription row.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

describe 'ExternalBridge unsubscribe and link sharing concurrency', type: :model do
  self.use_transactional_tests = false

  around do |example|
    Sidekiq::Testing.fake! { example.run }
  end

  before do
    allow(LinkCrawlWorker).to receive(:perform_async)
    RedisConfiguration.establish_pool(RedisConfiguration.pool_size)
    Thread.current[:redis] = nil
    stub_request(:any, %r{\Ahttps://example\.com/}).to_return(status: 200, body: '<html><head><title>x</title></head></html>', headers: { 'Content-Type' => 'text/html' })
    ExternalBridge::RSS::SubscriptionDeletionWorker.clear
    ExternalBridge::LinkWrapperRemovalWorker.clear
    ExternalBridge::LinkBoostAnnounceWorker.clear
    ActivityPub::DistributionWorker.clear
  end

  after do
    ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
    cleanup!
    Setting.external_bridge_link_sharing = false
    Setting.external_bridge_link_sharing_testers = ''
    Rails.cache.clear
  end

  def release_thread_redis!
    RedisConfiguration.pool.checkin
  rescue StandardError
    nil
  ensure
    Thread.current[:redis] = nil
  end

  def build_world
    @user = Fabricate(:user)
    @world = external_project_for(@user)
    @world[:source].update!(title: 'Safe Feed Title')
    @world[:resource].update!(canonical_url: "https://example.com/posts/#{SecureRandom.hex(5)}")
    enable_external_bridge_link_sharing!(@user)
    ExternalBridge::LinkSharing::Policy.grant!(user: @user, visibility: 'public')
  end

  def cleanup!
    return if @user.nil?

    user_id = @user.id
    Report.where(target_account_id: @user.account_id).delete_all
    reference_ids = ExternalProjectionLinkReference.where(user_id: user_id).pluck(:reference_status_id).compact
    Status.unscoped.where(reblog_of_id: reference_ids).delete_all
    ExternalProjectionLinkReference.where(user_id: user_id).delete_all
    Status.unscoped.where(id: reference_ids).delete_all
    ExternalLinkSharePolicy.where(user_id: user_id).delete_all
    source_ids = ExternalSubscription.where(user_id: user_id).pluck(:external_source_id) | [@world&.dig(:source)&.id].compact
    ExternalBridge::DeleteUser.call(User.find(user_id)) if User.exists?(user_id)
    ExternalResource.where(external_source_id: source_ids).delete_all
    ExternalSource.where(id: source_ids).delete_all
    Account.where(id: @user.account_id).destroy_all
  ensure
    @user = nil
  end

  # Blocks the thread that set Thread.current[:pause_at] when that checkpoint fires.
  def pause_checkpoint!(name)
    @entered = Queue.new
    @release = Queue.new
    @subscriber = ActiveSupport::Notifications.subscribe(ExternalBridge::LinkSharing::Checkpoints::EVENT) do |*args|
      payload = args.last
      next unless payload[:name] == name && Thread.current[:pause_at] == name

      @entered << true
      @release.pop
    end
  end

  def in_thread(pause_at: nil, &block)
    Thread.new do
      Thread.current[:pause_at] = pause_at
      Sidekiq::Testing.fake! { ActiveRecord::Base.connection_pool.with_connection(&block) }
    rescue StandardError => e
      Thread.current[:error] = e
      nil
    ensure
      release_thread_redis!
    end
  end

  def accept!
    ExternalBridge::RSS::Subscribe.new.unsubscribe!(user: User.find(@user.id), subscription_id: @world[:subscription].id)
  end

  def share_state
    {
      statuses: Status.unscoped.where(account_id: @user.account_id).where('external_projection IS NOT TRUE').count,
      references: ExternalProjectionLinkReference.where(user_id: @user.id).count,
      boosts: ExternalProjectionLinkBoost.where(user_id: @user.id).count,
    }
  end

  it 'refuses a share whose ownership check passed before the unsubscribe was accepted' do
    build_world
    before = share_state
    pause_checkpoint!(:after_ownership_check)

    sharer = in_thread(pause_at: :after_ownership_check) do
      ExternalBridge::LinkSharing::Boost.call(user: User.find(@user.id), status: Status.find(@world[:status].id))
    end
    @entered.pop
    begin
      accept!
      expect(ExternalSubscription.find(@world[:subscription].id).state).to eq 'deleting'
    ensure
      @release << true
      sharer.join
    end

    expect(sharer[:error]).to be_a(ExternalBridge::Error)
    expect(sharer[:error].code).to eq 'subscription_deleting'
    expect(share_state).to eq before
    expect(ExternalBridge::LinkBoostAnnounceWorker.jobs).to be_empty
    expect(ActivityPub::DistributionWorker.jobs).to be_empty
    expect(Status.unscoped.where(account_id: @user.account_id, text: 'RSS')).to be_empty
  end

  it 'waits for a share in progress, and the purge then retires it' do
    build_world
    pause_checkpoint!(:before_boost_create)

    sharer = in_thread(pause_at: :before_boost_create) do
      ExternalBridge::LinkSharing::Boost.call(user: User.find(@user.id), status: Status.find(@world[:status].id))
    end
    @entered.pop
    accepted = in_thread { accept! }
    begin
      sleep 0.6
      expect(accepted.alive?).to be true
      expect(ExternalSubscription.find(@world[:subscription].id).state).to eq 'active'
    ensure
      @release << true
      sharer.join
      accepted.join
    end

    expect(sharer[:error]).to be_nil
    expect(accepted[:error]).to be_nil
    boost = ExternalProjectionLinkBoost.find_by!(user_id: @user.id)
    expect(boost.state).to eq 'active'
    deletion = ExternalSubscriptionDeletion.find_by!(external_subscription_id: @world[:subscription].id)

    ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(deletion.id)

    expect(deletion.reload).to be_completed
    expect(boost.reload.state).to eq 'undone'
    expect(boost.ended_reason).to eq 'projection_purged'
    expect(Status.unscoped.exists?(boost.wrapper_status_id.to_i)).to be false
    expect(ExternalStatusProjection.where(external_subscription_id: @world[:subscription].id)).to be_empty
  end

  it 'closes an announce that is between its two phases when the unsubscribe is accepted' do
    build_world
    result = ExternalBridge::LinkSharing::Boost.call(user: @user, status: @world[:status])
    ExternalProjectionLinkReference.where(user_id: @user.id).update_all(published_at: Time.current)
    ExternalBridge::LinkBoostAnnounceWorker.clear
    pause_checkpoint!(:announce_between_phases)

    announcer = in_thread(pause_at: :announce_between_phases) { ExternalBridge::LinkSharing::BoostAnnounce.call(result.boost.id) }
    @entered.pop
    begin
      accept!
    ensure
      @release << true
      announcer.join
    end

    expect(announcer[:error]).to be_nil
    expect(announcer.value).to eq :closed
    boost = ExternalProjectionLinkBoost.find(result.boost.id)
    expect(boost.state).to eq 'undone'
    expect(boost.announce_enqueued_at).to be_nil
    expect(ActivityPub::DistributionWorker.jobs).to be_empty
    expect(ExternalBridge::LinkWrapperRemovalWorker.jobs.map { |job| job['args'].first }).to eq [result.wrapper.id]
  end

  it 'lets one of two Undo jobs for the same wrapper work and the other stand aside, even when the first is stopped before it acknowledges' do
    build_world
    result = ExternalBridge::LinkSharing::Boost.call(user: @user, status: @world[:status])
    result.boost.update_columns(announced_at: Time.current, announce_enqueued_at: Time.current)
    wrapper_id = result.wrapper.id
    Report.create!(account: Fabricate(:account), target_account: @user.account, status_ids: [wrapper_id], comment: '')
    deletion = accept!
    ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(deletion.id)
    boost = ExternalProjectionLinkBoost.find(result.boost.id)
    expect(boost.wrapper_status_id).to eq wrapper_id
    expect(boost.removal_acknowledged_at).to be_nil

    calls = Queue.new
    allow_any_instance_of(RemoveStatusService).to receive(:call).and_wrap_original do |method, *args, **kwargs|
      calls << true
      method.call(*args, **kwargs)
    end
    pause_checkpoint!(:removal_before_acknowledge)
    first = in_thread(pause_at: :removal_before_acknowledge) { ExternalBridge::LinkWrapperRemovalWorker.new.perform(wrapper_id) }
    @entered.pop
    begin
      second = in_thread { ExternalBridge::LinkWrapperRemovalWorker.new.perform(wrapper_id) }
      second.join
      expect(second[:error]).to be_nil
      expect(second.value).to be false
      expect(calls.size).to eq 1
      expect(ExternalProjectionLinkBoost.find(result.boost.id).removal_acknowledged_at).to be_nil
    ensure
      @release << true
      first.join
    end

    expect(first[:error]).to be_nil
    expect(ExternalProjectionLinkBoost.find(result.boost.id).removal_acknowledged_at).to be_present
    third = in_thread { ExternalBridge::LinkWrapperRemovalWorker.new.perform(wrapper_id) }
    third.join
    expect(third[:error]).to be_nil
    expect(calls.size).to eq 1
    expect(Status.unscoped.exists?(wrapper_id)).to be true

    removal = in_thread { RemovalWorker.new.perform(wrapper_id, 'immediate' => true) }
    removal.join
    expect(Status.unscoped.exists?(wrapper_id)).to be false
  end

  def advisory_locks
    ActiveRecord::Base.connection.select_value("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND database = (SELECT oid FROM pg_database WHERE datname = current_database())").to_i
  end

  def ended_reported_share
    build_world
    result = ExternalBridge::LinkSharing::Boost.call(user: @user, status: @world[:status])
    result.boost.update_columns(announced_at: Time.current, announce_enqueued_at: Time.current)
    Report.create!(account: Fabricate(:account), target_account: @user.account, status_ids: [result.wrapper.id], comment: '')
    ExternalBridge::RSS::SubscriptionDeletionRunner.new.call(accept!.id)
    result
  end

  it 'survives a change of database connection between the claim and the acknowledgement, and holds no session lock' do
    result = ended_reported_share
    wrapper_id = result.wrapper.id
    subscriber = ActiveSupport::Notifications.subscribe(ExternalBridge::LinkSharing::Checkpoints::EVENT) do |*args|
      ActiveRecord::Base.connection.reconnect! if args.last[:name] == :removal_before_acknowledge
    end

    thread = in_thread { ExternalBridge::LinkWrapperRemovalWorker.new.perform(wrapper_id) }
    thread.join
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(thread[:error]).to be_nil
    boost = ExternalProjectionLinkBoost.find(result.boost.id)
    expect(boost.removal_acknowledged_at).to be_present
    expect([boost.removal_lease_token, boost.removal_lease_until]).to eq [nil, nil]
    expect(advisory_locks).to eq 0
  end

  it 'covers a first worker that is killed before it acknowledges: its lease expires and the recovery pushes again' do
    result = ended_reported_share
    wrapper_id = result.wrapper.id
    calls = Queue.new
    allow_any_instance_of(RemoveStatusService).to receive(:call).and_wrap_original do |method, *args, **kwargs|
      calls << true
      method.call(*args, **kwargs)
    end
    pause_checkpoint!(:removal_before_acknowledge)
    first = in_thread(pause_at: :removal_before_acknowledge) { ExternalBridge::LinkWrapperRemovalWorker.new.perform(wrapper_id) }
    @entered.pop
    first.kill
    first.join
    ActiveSupport::Notifications.unsubscribe(@subscriber)
    @subscriber = nil

    boost = ExternalProjectionLinkBoost.find(result.boost.id)
    expect(boost.removal_lease_until).to be > 4.minutes.from_now
    expect(boost.removal_acknowledged_at).to be_nil
    expect(advisory_locks).to eq 0

    second = in_thread { ExternalBridge::LinkWrapperRemovalWorker.new.perform(wrapper_id) }
    second.join
    expect(second.value).to be false
    expect(calls.size).to eq 1

    pushed = []
    allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }
    boost.update_columns(removal_next_attempt_at: nil, updated_at: 1.hour.ago)
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0

    boost.update_columns(removal_lease_until: 1.second.ago)
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
    third = in_thread { ExternalBridge::LinkWrapperRemovalWorker.new.perform(wrapper_id) }
    third.join

    expect(pushed).to eq [wrapper_id]
    expect(calls.size).to eq 2
    expect(ExternalProjectionLinkBoost.find(result.boost.id).removal_acknowledged_at).to be_present
    expect(Status.unscoped.exists?(wrapper_id)).to be true
  end
end

# rubocop:enable Metrics/BlockLength
