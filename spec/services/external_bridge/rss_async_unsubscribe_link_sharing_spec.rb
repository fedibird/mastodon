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
    boost.update_columns(next_announce_at: nil)
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0
  end

  it 'lets the interrupted job resume to completion without pushing the removal twice' do
    world, result = announced_share
    deletion = unsubscribe!(world)
    allow(RemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
    runner.call(deletion.id)
    pushed = []
    allow(RemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }

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
    expect(ExternalProjectionLinkBoost.find(result.boost.id).next_announce_at).to be > 5.minutes.from_now
  end

  it 'releases the claim when the recovery push is refused, so the next pass tries again' do
    world, result = announced_share
    deletion = unsubscribe!(world)
    allow(RemovalWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)
    runner.call(deletion.id)

    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 0
    expect(ExternalProjectionLinkBoost.find(result.boost.id).next_announce_at).to be <= Time.current
    pushed = []
    allow(RemovalWorker).to receive(:perform_async) { |id| pushed << id && 'jid' }
    expect(ExternalBridge::LinkSharing::RecoverRemovals.call(settle: 0.seconds)).to eq 1
    expect(pushed).to eq [result.wrapper.id]
  end
end

# rubocop:enable Metrics/BlockLength
