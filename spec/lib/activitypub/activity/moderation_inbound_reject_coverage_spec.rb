require 'rails_helper'

# An inbound ActivityPub Reject of a *local* account's follow request (remote
# actor -> local requester) is recorded in the moderation ledger as a
# follow_reject rejection. The Reject bypasses RejectFollowService and destroys
# the FollowRequest, so the recorder is keyed on the Reject activity identity
# (activitypub_follow_reject:<Reject id>) rather than the destroyed record.
#
# Recording requires the Reject to correlate to a real outbound Follow from this
# server. A live matching FollowRequest is sufficient. After that row is gone,
# the embedded Follow id / bare URI must match a ModerationInteractionEvent
# keyed activitypub_outbound_follow:<follow-id> whose local actor is the claimed
# requester and whose target is the Reject sender. URI equality alone is not
# enough. A protocol-level Reject that only acknowledges our own Undo(Follow)
# (synthesized Follow id, no live request, no matching outbound-follow anchor)
# must not be recorded as follow_reject.
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

    it 'does not repair a missed ledger event when the embedded Follow id was never sent by us' do
      allow(Moderation::EventRecorder).to receive(:record_rejection).and_return(nil)
      deliver(json)

      expect(local.requested?(remote)).to be false
      expect(ModerationRejectionEvent.count).to eq 0

      allow(Moderation::EventRecorder).to receive(:record_rejection).and_call_original
      expect { deliver(json) }.to_not change(ModerationRejectionEvent, :count)
      expect(ModerationRejectionEvent.count).to eq 0
    end
  end

  # Genuine Reject of a Follow this server actually sent: the embedded Follow
  # id is the outbound FollowRequest URI recorded under
  # activitypub_outbound_follow:<uri>.
  context 'genuine Reject of an outbound Follow' do
    before { allow(ActivityPub::DeliveryWorker).to receive(:perform_async) }

    let!(:follow_request) { FollowService.new.call(local, remote) }

    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/reject-genuine',
        type: 'Reject',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: {
          id: follow_request.uri,
          type: 'Follow',
          actor: ActivityPub::TagManager.instance.uri_for(local),
          object: ActivityPub::TagManager.instance.uri_for(remote),
        },
      }.with_indifferent_access
    end

    it 'records a follow_reject for a Reject of an outbound Follow we sent' do
      expect { deliver(json) }.to change(ModerationRejectionEvent, :count).by(1)

      event = ModerationRejectionEvent.order(:id).last
      expect(event.event_type).to eq 'follow_reject'
      expect(event.rejector_subject.account_id).to eq remote.id
      expect(event.rejected_subject.account_id).to eq local.id
      expect(event.source_event_key).to eq 'activitypub_follow_reject:https://remote.example/activities/reject-genuine'
      expect(local.requested?(remote)).to be false
    end
  end

  # After reject! destroys the FollowRequest, re-delivery still records when
  # the embedded Follow id matches the outbound-follow interaction we wrote
  # at request time. The same Reject activity key is reused idempotently.
  context 'embedded-Follow redelivery after FollowRequest destruction with outbound-follow anchor' do
    before { allow(ActivityPub::DeliveryWorker).to receive(:perform_async) }

    let!(:follow_request) { FollowService.new.call(local, remote) }

    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/reject-redeliver',
        type: 'Reject',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: {
          id: follow_request.uri,
          type: 'Follow',
          actor: ActivityPub::TagManager.instance.uri_for(local),
          object: ActivityPub::TagManager.instance.uri_for(remote),
        },
      }.with_indifferent_access
    end

    it 'records on first delivery and reuses the same key on redelivery' do
      expect { deliver(json) }.to change(ModerationRejectionEvent, :count).by(1)
      expect { deliver(json) }.to_not change(ModerationRejectionEvent, :count)
      expect(ModerationRejectionEvent.count).to eq 1
      expect(ModerationRejectionEvent.order(:id).last.source_event_key)
        .to eq 'activitypub_follow_reject:https://remote.example/activities/reject-redeliver'
    end

    it 'repairs a missed ledger event via the outbound-follow anchor after the FollowRequest is gone' do
      allow(Moderation::EventRecorder).to receive(:record_rejection).and_return(nil)
      deliver(json)

      expect(local.requested?(remote)).to be false
      expect(ModerationRejectionEvent.count).to eq 0
      expect(FollowRequest.exists?(account: local, target_account: remote)).to be false

      allow(Moderation::EventRecorder).to receive(:record_rejection).and_call_original
      expect { deliver(json) }.to change(ModerationRejectionEvent, :count).by(1)

      event = ModerationRejectionEvent.order(:id).last
      expect(event.event_type).to eq 'follow_reject'
      expect(event.rejector_subject.account_id).to eq remote.id
      expect(event.rejected_subject.account_id).to eq local.id
      expect(event.source_event_key).to eq 'activitypub_follow_reject:https://remote.example/activities/reject-redeliver'
    end
  end

  # A synthesized embedded Follow whose id was never an outbound Follow from
  # this server must not become a moderation rejection, even if the claimed
  # actor/object pair looks locally plausible. Relationship cleanup is unchanged.
  context 'synthetic embedded Reject whose Follow id was never sent by us' do
    before do
      allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
      Fabricate(:follow, account: local, target_account: remote)
    end

    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/reject-synthetic',
        type: 'Reject',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: {
          id: 'https://remote.example/follows/never-sent-by-us',
          type: 'Follow',
          actor: ActivityPub::TagManager.instance.uri_for(local),
          object: ActivityPub::TagManager.instance.uri_for(remote),
        },
      }.with_indifferent_access
    end

    it 'does not record a follow_reject and still undoes the local follow' do
      expect { deliver(json) }.to_not change(ModerationRejectionEvent, :count)
      expect(local.following?(remote)).to be false
      expect(ModerationRejectionEvent.count).to eq 0
    end
  end

  # Misskey (and MisskeyIO) process inbound Undo(Follow) by unfollow() of the
  # remote follower, which sends Reject(Follow) built from renderFollow without
  # our outbound Follow activity id. That Reject is acknowledgement/cleanup of
  # our own unfollow, not a negative decision by the Misskey user.
  context 'Misskey-style Reject after our Undo(Follow)' do
    before { allow(ActivityPub::DeliveryWorker).to receive(:perform_async) }

    let!(:follow_request) { FollowService.new.call(local, remote) }

    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/reject-misskey-ack',
        type: 'Reject',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: {
          id: 'https://remote.example/follows/synthesized-without-request-id',
          type: 'Follow',
          actor: ActivityPub::TagManager.instance.uri_for(local),
          object: ActivityPub::TagManager.instance.uri_for(remote),
        },
      }.with_indifferent_access
    end

    before do
      UnfollowService.new.call(local, remote)
    end

    it 'does not record a follow_reject or count as a negative signal' do
      expect(local.requested?(remote)).to be false
      expect(ModerationInteractionEvent.find_by(source_event_key: "activitypub_outbound_follow:#{follow_request.uri}")).to be_present

      expect { deliver(json) }.to_not change(ModerationRejectionEvent, :count)
      expect(ModerationRejectionEvent.count).to eq 0

      metrics = Moderation::BehavioralMetricsService.new.call(local)
      expect(metrics.dig('lifetime', 'follow_rejects_received')).to eq 0
      expect(metrics.dig('lifetime', 'first_negative_signal_at')).to be_nil
      expect(metrics.dig('lifetime', 'new_targets_after_first_negative_signal')).to eq 0
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

    it 'records the outbound follow interaction under the direction-specific AP activity-identity key' do
      interaction = ModerationInteractionEvent.find_by(source_event_key: "activitypub_outbound_follow:#{follow_request.uri}")

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

  # Adversarial: URI equality alone must not bind identities. An outbound follow
  # local -> remote_other creates the anchor; a *different* remote then sends a
  # bare-URI Reject echoing that other follow's URI (as if leaked/reused). The
  # target-identity invariant must reject the correlation, so no follow_reject is
  # synthesized for the wrong remote.
  context 'bare follow-request-URI shape, cross-account anchor (must not repair)' do
    before { allow(ActivityPub::DeliveryWorker).to receive(:perform_async) }

    let(:remote_other) do
      Fabricate(:account, domain: 'other.example', uri: 'https://other.example/users/carol', inbox_url: 'https://other.example/inbox', protocol: :activitypub)
    end
    let!(:other_follow_request) { FollowService.new.call(local, remote_other) }

    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/reject-evil',
        type: 'Reject',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: other_follow_request.uri,
      }.with_indifferent_access
    end

    it 'has an anchor whose target is the other remote, not the Reject actor' do
      interaction = ModerationInteractionEvent.find_by(source_event_key: "activitypub_outbound_follow:#{other_follow_request.uri}")

      expect(interaction).to be_present
      expect(interaction.actor_subject.account_id).to eq local.id
      expect(interaction.target_subject.account_id).to eq remote_other.id
    end

    it 'does not synthesize a follow_reject when the anchor targets a different remote' do
      # No FollowRequest exists for (local -> remote), so the repair path runs and
      # the target-identity invariant must reject the mismatched anchor.
      expect { deliver(json) }.to_not change(ModerationRejectionEvent, :count)
      expect { deliver(json) }.to_not change(ModerationRejectionEvent, :count)
      expect(ModerationRejectionEvent.count).to eq 0
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
