# frozen_string_literal: true

# E4 contract of the asynchronous unsubscribe: an announced wrapper must reach
# ExternalBridge::LinkWrapperRemovalWorker (the Undo) even when the push that follows the batch commit is
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
    allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)

    # The removal enqueue is after the commit. Redis refusing it does not fail
    # the deletion or roll back the undone boost. RecoverRemovals pushes again.
    expect(runner.call(deletion.id)).to eq :completed

    boost = ExternalProjectionLinkBoost.find(result.boost.id)
    expect(boost.state).to eq 'undone'
    expect(boost.ended_reason).to eq 'projection_purged'
    expect(boost.wrapper_status_id).to eq wrapper_id
    expect(Status.unscoped.find(wrapper_id).deleted_at).to be_present
    expect(ExternalStatusProjection.where(id: world[:marker].id)).to be_empty
    expect(deletion.reload).to be_completed
    expect(deletion.last_error_code).to be_nil
    expect(ExternalBridge::LinkSharing::Retire.end_orphans!).to eq 0

    pushed = []
    allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
    expect(pushed).to eq [wrapper_id]
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0

    expect_any_instance_of(RemoveStatusService).to receive(:call).and_call_original
    ExternalBridge::LinkWrapperRemovalWorker.new.perform(wrapper_id)
    expect(Status.unscoped.exists?(wrapper_id)).to be false
    expect(boost.reload.wrapper_status_id).to be_nil
    expect { ExternalBridge::LinkWrapperRemovalWorker.new.perform(wrapper_id) }.not_to raise_error
    boost.update_columns(removal_next_attempt_at: nil)
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0
    expect(boost.reload.removal_acknowledged_at).to be_present
  end

  it 'lets the interrupted job resume to completion without pushing the removal twice' do
    world, result = announced_share
    deletion = unsubscribe!(world)
    allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
    runner.call(deletion.id)
    pushed = []
    allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }

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
    allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
    runner.call(deletion.id)
    ExternalProjectionLinkBoost.where(id: result.boost.id).update_all(updated_at: 5.minutes.ago)
    pushed = []
    allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }

    Scheduler::ExternalBridgeLinkReferencePublishScheduler.new.perform
    Scheduler::ExternalBridgeLinkReferencePublishScheduler.new.perform

    expect(pushed).to eq [result.wrapper.id]
    expect(ExternalProjectionLinkBoost.find(result.boost.id).removal_next_attempt_at).to be > 5.minutes.from_now
  end

  it 'releases the claim when the recovery push is refused, so the next pass tries again' do
    world, result = announced_share
    deletion = unsubscribe!(world)
    allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
    runner.call(deletion.id)

    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0
    expect(ExternalProjectionLinkBoost.find(result.boost.id).removal_next_attempt_at).to be <= Time.current
    pushed = []
    allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }
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
      allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
      runner.call(deletion.id)
      pushed = []
      allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }
      expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
      expect(pushed).to eq [wrapper_id]

      calls = count_removals
      ExternalBridge::LinkWrapperRemovalWorker.new.perform(wrapper_id)

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
      ExternalBridge::LinkWrapperRemovalWorker.new.perform(wrapper_id)
      expect(calls.call).to eq 1
      expect(Status.unscoped.exists?(wrapper_id)).to be true
    end

    it 'still honours an explicit request to the general RemovalWorker for the same acknowledged wrapper' do
      world, result = reported_share
      wrapper_id = result.wrapper.id
      runner.call(unsubscribe!(world).id)
      ExternalBridge::LinkWrapperRemovalWorker.new.perform(wrapper_id)
      expect(ExternalProjectionLinkBoost.find(result.boost.id).removal_acknowledged_at).to be_present
      expect(Status.unscoped.exists?(wrapper_id)).to be true

      RemovalWorker.new.perform(wrapper_id, 'immediate' => true)

      expect(Status.unscoped.exists?(wrapper_id)).to be false
      expect(ExternalProjectionLinkBoost.find(result.boost.id).wrapper_status_id).to be_nil
    end

    it 'leaves RemovalWorker as Mastodon wrote it: no E4 early return, no acknowledgement' do
      world, result = reported_share
      runner.call(unsubscribe!(world).id)
      calls = count_removals

      2.times { RemovalWorker.new.perform(result.wrapper.id) }

      expect(calls.call).to eq 2
      expect(ExternalProjectionLinkBoost.find(result.boost.id).removal_acknowledged_at).to be_nil
    end

    it 'does not remove or Undo a second time when the same push arrives twice' do
      world, result = reported_share
      runner.call(unsubscribe!(world).id)
      calls = count_removals

      2.times { ExternalBridge::LinkWrapperRemovalWorker.new.perform(result.wrapper.id) }

      expect(calls.call).to eq 1
    end
  end

  it 'does not acknowledge a removal whose RemoveStatusService failed, so the recovery tries again' do
    world, result = announced_share
    runner.call(unsubscribe!(world).id)
    allow_any_instance_of(RemoveStatusService).to receive(:call).and_raise(Redis::CannotConnectError)

    expect { ExternalBridge::LinkWrapperRemovalWorker.new.perform(result.wrapper.id) }.to raise_error(Redis::CannotConnectError)

    boost = ExternalProjectionLinkBoost.find(result.boost.id)
    expect(boost.removal_acknowledged_at).to be_nil
    boost.update_columns(removal_next_attempt_at: nil)
    pushed = []
    allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
    expect(pushed).to eq [result.wrapper.id]
  end

  it 'is not delayed by the claim of the original Announce when a share ends soon after it was made' do
    world, result = announced_share
    result.boost.update_columns(next_announce_at: 25.minutes.from_now)
    allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
    runner.call(unsubscribe!(world).id)
    boost = ExternalProjectionLinkBoost.find(result.boost.id)
    expect(boost.next_announce_at).to be > 20.minutes.from_now
    pushed = []
    allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }

    expect(ExternalBridge::LinkSharing::RecoverRemovals.call).to eq 0
    boost.update_columns(updated_at: (ExternalBridge::LinkSharing::RecoverRemovals::SETTLE + 1.second).ago)
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call).to eq 1
    expect(pushed).to eq [result.wrapper.id]
  end

  describe 'the lease of the wrapper removal (no database session involved)' do
    def ended_share
      world, result = announced_share
      runner.call(unsubscribe!(world).id)
      [result, ExternalProjectionLinkBoost.find(result.boost.id)]
    end

    def count_removals
      calls = 0
      allow_any_instance_of(RemoveStatusService).to receive(:call).and_wrap_original do |method, *args, **kwargs|
        calls += 1
        method.call(*args, **kwargs)
      end
      -> { calls }
    end

    it 'does nothing and is not retried while another job holds a live lease, and the scan leaves the row alone until it expires' do
      result, boost = ended_share
      boost.update_columns(removal_lease_token: 'otherjob', removal_lease_until: 3.minutes.from_now, removal_next_attempt_at: nil, updated_at: 1.hour.ago)
      calls = count_removals
      pushed = []
      allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }

      expect(ExternalBridge::LinkWrapperRemovalWorker.new.perform(result.wrapper.id)).to be false
      expect(calls.call).to eq 0
      expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0
      expect(pushed).to be_empty

      boost.update_columns(removal_lease_until: 1.second.ago)
      expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
      expect(pushed).to eq [result.wrapper.id]
      ExternalBridge::LinkWrapperRemovalWorker.new.perform(result.wrapper.id)

      boost.reload
      expect(calls.call).to eq 1
      expect(boost.removal_acknowledged_at).to be_present
      expect([boost.removal_lease_token, boost.removal_lease_until]).to eq [nil, nil]
    end

    it 'lets only the current lease holder acknowledge' do
      result, boost = ended_share
      wrapper_id = result.wrapper.id
      retire = ExternalBridge::LinkSharing::Retire
      expect(retire.claim_removal!(wrapper_id, 'first', 5.minutes)).to be true
      expect(retire.claim_removal!(wrapper_id, 'second', 5.minutes)).to be false

      boost.reload.update_columns(removal_lease_until: 1.second.ago)
      expect(retire.claim_removal!(wrapper_id, 'second', 5.minutes)).to be true
      expect(retire.acknowledge_removal!('first')).to be false
      expect(boost.reload.removal_acknowledged_at).to be_nil
      expect(retire.acknowledge_removal!('second')).to be true
      expect(boost.reload.removal_acknowledged_at).to be_present
      expect(retire.claim_removal!(wrapper_id, 'third', 5.minutes)).to be false
    end

    it 'gives the lease back when the work fails, so the next push does not wait for the expiry' do
      result, boost = ended_share
      allow_any_instance_of(RemoveStatusService).to receive(:call).and_raise(Redis::CannotConnectError)

      expect { ExternalBridge::LinkWrapperRemovalWorker.new.perform(result.wrapper.id) }.to raise_error(Redis::CannotConnectError)

      boost.reload
      expect([boost.removal_lease_token, boost.removal_lease_until, boost.removal_acknowledged_at]).to eq [nil, nil, nil]
      allow_any_instance_of(RemoveStatusService).to receive(:call).and_call_original
      ExternalBridge::LinkWrapperRemovalWorker.new.perform(result.wrapper.id)
      expect(boost.reload.removal_acknowledged_at).to be_present
    end

    it 'does not use a database session lock' do
      result, = ended_share
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        ExternalBridge::LinkWrapperRemovalWorker.new.perform(result.wrapper.id)
      end

      expect(statements.grep(/advisory/i)).to be_empty
    end
  end
end

# rubocop:enable Metrics/BlockLength
