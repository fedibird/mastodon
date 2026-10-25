# frozen_string_literal: true

# E4 contract of the asynchronous unsubscribe: an announced wrapper must reach
# RemovalWorker (the Undo) even when the push that follows the batch commit is
# lost.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

describe 'ExternalBridge asynchronous RSS unsubscribe and link sharing', type: :model do
  around do |example|
    Sidekiq::Testing.fake! { example.run }
  end

  let(:user) { Fabricate(:user) }
  let(:runner) { ExternalBridge::RSS::SubscriptionDeletionRunner.new }

  before do
    allow(LinkCrawlWorker).to receive(:perform_async)
    stub_request(:any, %r{\Ahttps://example\.com/}).to_return(status: 200, body: '<html><head><title>x</title></head></html>', headers: { 'Content-Type' => 'text/html' })
    ExternalBridge::RSS::SubscriptionDeletionWorker.clear
  end

  after do
    Setting.external_bridge_link_sharing = false
    Setting.external_bridge_link_sharing_testers = ''
  end

  def announced_share
    world = external_project_for(user)
    world[:source].update!(title: 'Safe Feed Title')
    world[:resource].update!(canonical_url: "https://example.com/posts/#{SecureRandom.hex(5)}")
    enable_external_bridge_link_sharing!(user)
    ExternalBridge::LinkSharing::Policy.grant!(user: user, visibility: 'public')
    result = ExternalBridge::LinkSharing::Boost.call(user: user, status: world[:status])
    result.boost.update_columns(announced_at: Time.current, announce_enqueued_at: Time.current)
    [world, result]
  end

  def unsubscribe!(world)
    ExternalBridge::RSS::Subscribe.new.unsubscribe!(user: user, subscription_id: world[:subscription].id)
  end

  it 'recovers the Undo of an announced wrapper when the push after the batch commit is lost' do
    world, result = announced_share
    wrapper_id = result.wrapper.id
    deletion = unsubscribe!(world)
    allow(RemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)

    expect(runner.call(deletion.id)).to eq :failed

    boost = ExternalProjectionLinkBoost.find(result.boost.id)
    expect(boost.state).to eq 'undone'
    expect(boost.ended_reason).to eq 'projection_purged'
    expect(boost.wrapper_status_id).to eq wrapper_id
    expect(Status.unscoped.find(wrapper_id).deleted_at).to be_present
    expect(ExternalStatusProjection.where(id: world[:marker].id)).to be_empty
    expect(deletion.reload).to be_failed
    expect(deletion.last_error_code).to eq 'queue_error'
    expect(ExternalBridge::LinkSharing::Retire.end_orphans!).to eq 0

    pushed = []
    allow(RemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
    expect(pushed).to eq [wrapper_id]
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0

    expect_any_instance_of(RemoveStatusService).to receive(:call).and_call_original
    RemovalWorker.new.perform(wrapper_id)
    expect(Status.unscoped.exists?(wrapper_id)).to be false
    expect(boost.reload.wrapper_status_id).to be_nil
    expect { RemovalWorker.new.perform(wrapper_id) }.not_to raise_error
    boost.update_columns(removal_next_attempt_at: nil)
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0
    expect(boost.reload.removal_acknowledged_at).to be_nil
  end

  it 'lets the interrupted job resume to completion without pushing the removal twice' do
    world, result = announced_share
    deletion = unsubscribe!(world)
    allow(RemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
    runner.call(deletion.id)
    pushed = []
    allow(RemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }

    deletion.update_columns(next_run_at: 1.minute.ago)
    Scheduler::ExternalBridgeRSSSubscriptionDeletionScheduler.new.perform

    expect(runner.call(deletion.id)).to eq :completed

    expect(deletion.reload).to be_completed
    expect(deletion.deleted_count).to eq 1
    expect(pushed).to be_empty
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
    expect(ExternalProjectionLinkBoost.find(result.boost.id).state).to eq 'undone'
  end

  it 'leaves a wrapper that never left the server out of the recovery scan and ignores active rows' do
    world = external_project_for(user)
    world[:source].update!(title: 'Safe Feed Title')
    world[:resource].update!(canonical_url: "https://example.com/posts/#{SecureRandom.hex(5)}")
    enable_external_bridge_link_sharing!(user)
    ExternalBridge::LinkSharing::Policy.grant!(user: user, visibility: 'public')
    ExternalBridge::LinkSharing::Boost.call(user: user, status: world[:status])
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0

    runner.call(unsubscribe!(world).id)

    expect(ExternalProjectionLinkBoost.where(state: 'undone', wrapper_status_id: nil).count).to eq 1
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0
  end

  it 'runs the recovery in the existing link reference scheduler pass and holds it out for ten minutes' do
    world, result = announced_share
    deletion = unsubscribe!(world)
    allow(RemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
    runner.call(deletion.id)
    ExternalProjectionLinkBoost.where(id: result.boost.id).update_all(updated_at: 5.minutes.ago)
    pushed = []
    allow(RemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }

    Scheduler::ExternalBridgeLinkReferencePublishScheduler.new.perform
    Scheduler::ExternalBridgeLinkReferencePublishScheduler.new.perform

    expect(pushed).to eq [result.wrapper.id]
    expect(ExternalProjectionLinkBoost.find(result.boost.id).removal_next_attempt_at).to be > 5.minutes.from_now
  end

  it 'releases the claim when the recovery push is refused, so the next pass tries again' do
    world, result = announced_share
    deletion = unsubscribe!(world)
    allow(RemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
    runner.call(deletion.id)

    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0
    expect(ExternalProjectionLinkBoost.find(result.boost.id).removal_next_attempt_at).to be <= Time.current
    pushed = []
    allow(RemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
    expect(pushed).to eq [result.wrapper.id]
  end

  describe 'a wrapper that Mastodon keeps (an unresolved report)' do
    def reported_share
      world, result = announced_share
      Fabricate(:report, target_account: user.account, status_ids: [result.wrapper.id])
      expect(Status.find(result.wrapper.id)).to be_reported
      [world, result]
    end

    it 'is Undone once, kept for the report, acknowledged, and not pushed again by the recovery' do
      world, result = reported_share
      wrapper_id = result.wrapper.id
      deletion = unsubscribe!(world)
      allow(RemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
      runner.call(deletion.id)
      pushed = []
      allow(RemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }
      expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
      expect(pushed).to eq [wrapper_id]

      calls = 0
      allow_any_instance_of(RemoveStatusService).to receive(:call).and_wrap_original do |method, *args, **kwargs|
        calls += 1
        method.call(*args, **kwargs)
      end
      RemovalWorker.new.perform(wrapper_id)

      boost = ExternalProjectionLinkBoost.find(result.boost.id)
      expect(calls).to eq 1
      expect(Status.unscoped.find(wrapper_id).deleted_at).to be_present
      expect(boost.wrapper_status_id).to eq wrapper_id
      expect(boost.removal_acknowledged_at).to be_present
      expect(boost.state).to eq 'undone'

      boost.update_columns(removal_next_attempt_at: 1.minute.ago, updated_at: 1.hour.ago)
      pushed.clear
      expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0
      expect(Scheduler::ExternalBridgeLinkReferencePublishScheduler.new.perform).to be_a(Integer)
      expect(pushed).to be_empty
      RemovalWorker.new.perform(wrapper_id)
      expect(calls).to eq 1
      expect(Status.unscoped.exists?(wrapper_id)).to be true
    end

    it 'does not remove or Undo a second time when the same push arrives twice' do
      world, result = reported_share
      deletion = unsubscribe!(world)
      runner.call(deletion.id)
      calls = 0
      allow_any_instance_of(RemoveStatusService).to receive(:call).and_wrap_original do |method, *args, **kwargs|
        calls += 1
        method.call(*args, **kwargs)
      end

      2.times { RemovalWorker.new.perform(result.wrapper.id) }

      expect(calls).to eq 1
    end

    it 'does not acknowledge a removal whose RemoveStatusService failed, so the recovery tries again' do
      world, result = announced_share
      runner.call(unsubscribe!(world).id)
      allow_any_instance_of(RemoveStatusService).to receive(:call).and_raise(Redis::CannotConnectError)

      expect { RemovalWorker.new.perform(result.wrapper.id) }.to raise_error(Redis::CannotConnectError)

      boost = ExternalProjectionLinkBoost.find(result.boost.id)
      expect(boost.removal_acknowledged_at).to be_nil
      boost.update_columns(removal_next_attempt_at: nil)
      pushed = []
      allow(RemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }
      expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
      expect(pushed).to eq [result.wrapper.id]
    end
  end

  describe 'the claim of the original Announce' do
    it 'does not delay the recovery: a share that ends soon after its Announce is recovered after the settle time' do
      world, result = announced_share
      result.boost.update_columns(next_announce_at: 25.minutes.from_now)
      deletion = unsubscribe!(world)
      allow(RemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
      runner.call(deletion.id)
      boost = ExternalProjectionLinkBoost.find(result.boost.id)
      expect(boost.next_announce_at).to be > 20.minutes.from_now
      pushed = []
      allow(RemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }

      expect(ExternalBridge::LinkSharing::RecoverRemovals.call).to eq 0
      boost.update_columns(updated_at: (ExternalBridge::LinkSharing::RecoverRemovals::SETTLE + 1.second).ago)
      expect(ExternalBridge::LinkSharing::RecoverRemovals.call).to eq 1
      expect(pushed).to eq [result.wrapper.id]
    end
  end

  describe 'a wrapper that Mastodon keeps (an unresolved report)' do
    def reported_share
      world, result = announced_share
      Fabricate(:report, target_account: user.account, status_ids: [result.wrapper.id])
      expect(Status.find(result.wrapper.id)).to be_reported
      [world, result]
    end

    def count_removals
      calls = 0
      allow_any_instance_of(RemoveStatusService).to receive(:call).and_wrap_original do |method, *args, **kwargs|
        calls += 1
        method.call(*args, **kwargs)
      end
      -> { calls }
    end

    it 'is Undone once, kept for the report, acknowledged, and not pushed again by the recovery' do
      world, result = reported_share
      wrapper_id = result.wrapper.id
      deletion = unsubscribe!(world)
      allow(RemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
      runner.call(deletion.id)
      pushed = []
      allow(RemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }
      expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
      expect(pushed).to eq [wrapper_id]

      calls = count_removals
      RemovalWorker.new.perform(wrapper_id)

      boost = ExternalProjectionLinkBoost.find(result.boost.id)
      expect(calls.call).to eq 1
      expect(Status.unscoped.find(wrapper_id).deleted_at).to be_present
      expect(boost.wrapper_status_id).to eq wrapper_id
      expect(boost.removal_acknowledged_at).to be_present
      expect(boost.state).to eq 'undone'

      boost.update_columns(removal_next_attempt_at: 1.minute.ago, updated_at: 1.hour.ago)
      pushed.clear
      expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0
      Scheduler::ExternalBridgeLinkReferencePublishScheduler.new.perform
      expect(pushed).to be_empty
      RemovalWorker.new.perform(wrapper_id)
      expect(calls.call).to eq 1
      expect(Status.unscoped.exists?(wrapper_id)).to be true
    end

    it 'does not remove or Undo a second time when the same push arrives twice' do
      world, result = reported_share
      runner.call(unsubscribe!(world).id)
      calls = count_removals

      2.times { RemovalWorker.new.perform(result.wrapper.id) }

      expect(calls.call).to eq 1
    end
  end

  it 'does not acknowledge a removal whose RemoveStatusService failed, so the recovery tries again' do
    world, result = announced_share
    runner.call(unsubscribe!(world).id)
    allow_any_instance_of(RemoveStatusService).to receive(:call).and_raise(Redis::CannotConnectError)

    expect { RemovalWorker.new.perform(result.wrapper.id) }.to raise_error(Redis::CannotConnectError)

    boost = ExternalProjectionLinkBoost.find(result.boost.id)
    expect(boost.removal_acknowledged_at).to be_nil
    boost.update_columns(removal_next_attempt_at: nil)
    pushed = []
    allow(RemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
    expect(pushed).to eq [result.wrapper.id]
  end

  it 'is not delayed by the claim of the original Announce when a share ends soon after it was made' do
    world, result = announced_share
    result.boost.update_columns(next_announce_at: 25.minutes.from_now)
    allow(RemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
    runner.call(unsubscribe!(world).id)
    boost = ExternalProjectionLinkBoost.find(result.boost.id)
    expect(boost.next_announce_at).to be > 20.minutes.from_now
    pushed = []
    allow(RemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }

    expect(ExternalBridge::LinkSharing::RecoverRemovals.call).to eq 0
    boost.update_columns(updated_at: (ExternalBridge::LinkSharing::RecoverRemovals::SETTLE + 1.second).ago)
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call).to eq 1
    expect(pushed).to eq [result.wrapper.id]
  end
end

# rubocop:enable Metrics/BlockLength
