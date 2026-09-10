require 'rails_helper'

# An inbound ActivityPub Reject of a *local* account's follow request (remote
# actor -> local requester) is recorded in the moderation ledger as a
# follow_reject rejection. The Reject bypasses RejectFollowService and destroys
# the FollowRequest, so the recorder is keyed on the Reject activity identity
# (activitypub_follow_reject:<Reject id>) rather than the destroyed record.
#
# There are two inbound shapes:
#   * embedded Follow  — the rejected local account is derived from the embedded
#     Follow's actor, so recording still works (and REPAIRS a missed ledger
#     event on re-delivery) after reject! has destroyed the FollowRequest.
#   * bare follow-request URI — the FollowRequest's URI is an opaque payload id
#     that does not encode the requester, so after reject! destroys it a
#     re-delivery repairs an ordinary recorder-only failure by correlating that
#     URI to the outbound follow interaction recorded at request time
#     (activitypub_follow:<uri>). The event is lost only under a double recorder
#     failure (both the outbound follow and the inbound reject failed to record).
RSpec.describe 'Inbound ActivityPub follow-reject moderation coverage', type: :model do
  let(:remote) { Fabricate(:account, domain: 'remote.example', uri: 'https://remote.example/users/bob', inbox_url: 'https://remote.example/inbox', protocol: :activitypub) }
  let(:local)  { Fabricate(:account) }

  def deliver(json)
    ActivityPub::Activity::Reject.new(json, remote).perform
  end

  context 'embedded-Follow shape' do
    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/reject-1',
        type: 'Reject',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: {
          id: 'https://remote.example/activities/follow-1',
          type: 'Follow',
          actor: ActivityPub::TagManager.instance.uri_for(local),
          object: ActivityPub::TagManager.instance.uri_for(remote),
        },
      }.with_indifferent_access
    end

    before { Fabricate(:follow_request, account: local, target_account: remote) }

    it 'records a follow_reject rejection from the remote actor with a stable activity-identity key' do
      expect { deliver(json) }.to change(ModerationRejectionEvent, :count).by(1)

      event = ModerationRejectionEvent.order(:id).last
      expect(event.event_type).to eq 'follow_reject'
      expect(event.rejector_subject.account_id).to eq remote.id
      expect(event.rejected_subject.account_id).to eq local.id
      expect(event.source_event_key).to eq 'activitypub_follow_reject:https://remote.example/activities/reject-1'
      expect(local.requested?(remote)).to be false
    end

    it 'does not double-record on ordinary re-delivery' do
      deliver(json)
      expect { deliver(json) }.to_not change(ModerationRejectionEvent, :count)
    end

    it 're-delivery repairs a ledger event missed by a transient recorder failure' do
      allow(Moderation::EventRecorder).to receive(:record_rejection).and_return(nil)
      deliver(json)

      expect(local.requested?(remote)).to be false
      expect(ModerationRejectionEvent.count).to eq 0

      allow(Moderation::EventRecorder).to receive(:record_rejection).and_call_original
      expect { deliver(json) }.to change(ModerationRejectionEvent, :count).by(1)
      expect(ModerationRejectionEvent.count).to eq 1
      expect(ModerationRejectionEvent.order(:id).last.source_event_key)
        .to eq 'activitypub_follow_reject:https://remote.example/activities/reject-1'
    end
  end

  # Bare-URI shape with the outbound follow interaction present as a correlation
  # anchor: a realistic outbound follow to the remote records the follow
  # interaction under activitypub_follow:<uri>, which the reject repair uses.
  context 'bare follow-request-URI shape (single recorder-only failure is repairable)' do
    before { allow(ActivityPub::DeliveryWorker).to receive(:perform_async) }

    let!(:follow_request) { FollowService.new.call(local, remote) }

    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/reject-2',
        type: 'Reject',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: follow_request.uri,
      }.with_indifferent_access
    end

    it 'records the outbound follow interaction under the AP activity-identity key' do
      interaction = ModerationInteractionEvent.find_by(source_event_key: "activitypub_follow:#{follow_request.uri}")

      expect(interaction).to be_present
      expect(interaction.event_type).to eq 'follow'
      expect(interaction.actor_subject.account_id).to eq local.id
      expect(interaction.target_subject.account_id).to eq remote.id
    end

    it 'records a follow_reject on first delivery with a stable activity-identity key' do
      expect { deliver(json) }.to change(ModerationRejectionEvent, :count).by(1)

      event = ModerationRejectionEvent.order(:id).last
      expect(event.event_type).to eq 'follow_reject'
      expect(event.rejector_subject.account_id).to eq remote.id
      expect(event.rejected_subject.account_id).to eq local.id
      expect(event.source_event_key).to eq 'activitypub_follow_reject:https://remote.example/activities/reject-2'
      expect(local.requested?(remote)).to be false
    end

    it 'repairs a recorder-only reject failure on re-delivery via the follow correlation' do
      # First delivery: reject! destroys the FollowRequest, but the reject
      # recorder transiently fails, so no rejection is written.
      allow(Moderation::EventRecorder).to receive(:record_rejection).and_return(nil)
      deliver(json)

      expect(local.requested?(remote)).to be false
      expect(ModerationRejectionEvent.count).to eq 0

      # Re-delivery: the FollowRequest is gone, so the requester is recovered
      # from the surviving outbound follow interaction anchor.
      allow(Moderation::EventRecorder).to receive(:record_rejection).and_call_original
      expect { deliver(json) }.to change(ModerationRejectionEvent, :count).by(1)

      event = ModerationRejectionEvent.order(:id).last
      expect(event.event_type).to eq 'follow_reject'
      expect(event.rejector_subject.account_id).to eq remote.id
      expect(event.rejected_subject.account_id).to eq local.id
      expect(event.source_event_key).to eq 'activitypub_follow_reject:https://remote.example/activities/reject-2'
    end

    it 'does not double-record on ordinary re-delivery' do
      deliver(json)
      expect(ModerationRejectionEvent.count).to eq 1
      expect { deliver(json) }.to_not change(ModerationRejectionEvent, :count)
      expect(ModerationRejectionEvent.count).to eq 1
    end
  end

  # Bare-URI shape with NO correlation anchor: the outbound follow interaction
  # was never recorded (its recorder also failed), modeling the residual double
  # recorder failure. A recorder-only reject failure then cannot be repaired.
  context 'bare follow-request-URI shape (double recorder failure is not repairable)' do
    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/reject-2b',
        type: 'Reject',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: 'https://remote.example/activities/follow-2b',
      }.with_indifferent_access
    end

    before do
      # Fabricate the FollowRequest directly so no follow interaction anchor
      # exists (as if the outbound follow recording had also failed).
      Fabricate(:follow_request, account: local, target_account: remote, uri: 'https://remote.example/activities/follow-2b')
    end

    it 'records a follow_reject on first delivery (captured before reject!)' do
      expect { deliver(json) }.to change(ModerationRejectionEvent, :count).by(1)

      event = ModerationRejectionEvent.order(:id).last
      expect(event.event_type).to eq 'follow_reject'
      expect(event.rejector_subject.account_id).to eq remote.id
      expect(event.rejected_subject.account_id).to eq local.id
      expect(event.source_event_key).to eq 'activitypub_follow_reject:https://remote.example/activities/reject-2b'
    end

    it 'cannot repair a missed ledger event on re-delivery (no correlation anchor)' do
      allow(Moderation::EventRecorder).to receive(:record_rejection).and_return(nil)
      deliver(json)

      expect(local.requested?(remote)).to be false
      expect(ModerationRejectionEvent.count).to eq 0

      allow(Moderation::EventRecorder).to receive(:record_rejection).and_call_original
      expect { deliver(json) }.to_not change(ModerationRejectionEvent, :count)
      expect(ModerationRejectionEvent.count).to eq 0
    end
  end

  context 'Reject of an already-established follow' do
    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/reject-3',
        type: 'Reject',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: 'https://remote.example/activities/follow-3',
      }.with_indifferent_access
    end

    before do
      # UnfollowService (the modeled handling of this shape) emits an outbound
      # Undo; stub delivery so it does not hit the network.
      allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
      Fabricate(:follow, account: local, target_account: remote, uri: 'https://remote.example/activities/follow-3')
    end

    it 'is treated as an unfollow and is intentionally not recorded as a follow_reject' do
      expect { deliver(json) }.to_not change(ModerationRejectionEvent, :count)
      expect(local.following?(remote)).to be false
    end
  end
end
