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
    RemovalWorker.clear
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
    expect(RemovalWorker.jobs.map { |job| job['args'].first }).to eq [result.wrapper.id]
  end
end

# rubocop:enable Metrics/BlockLength
