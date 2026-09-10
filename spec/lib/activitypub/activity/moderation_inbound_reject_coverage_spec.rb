require 'rails_helper'

# PR 6c: an inbound ActivityPub Reject of a *local* account's follow request
# (remote actor -> local requester) is recorded in the moderation ledger as a
# follow_reject rejection. The Reject bypasses RejectFollowService and destroys
# the FollowRequest, so the recorder is keyed on the Reject activity identity
# (activitypub_follow_reject:<Reject id>) rather than the destroyed record.
#
# There are two inbound shapes:
#   * embedded Follow  — the rejected local account is derived from the embedded
#     Follow's actor, so recording still works (and REPAIRS a missed ledger
#     event on re-delivery) after reject! has destroyed the FollowRequest.
#   * bare follow-request URI — the local requester is captured before reject!
#     destroys the FollowRequest, so it records on first delivery but cannot
#     self-repair on re-delivery (the record it reads from is gone).
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

  context 'bare follow-request-URI shape' do
    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/reject-2',
        type: 'Reject',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: 'https://remote.example/activities/follow-2',
      }.with_indifferent_access
    end

    before do
      Fabricate(:follow_request, account: local, target_account: remote, uri: 'https://remote.example/activities/follow-2')
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

    it 'does not double-record on re-delivery (the FollowRequest is already gone)' do
      deliver(json)
      expect { deliver(json) }.to_not change(ModerationRejectionEvent, :count)
      expect(ModerationRejectionEvent.count).to eq 1
    end

    # Known, documented limitation: unlike the embedded-Follow shape, this shape
    # cannot self-repair because reject! has already destroyed the FollowRequest
    # the rejected account is read from.
    it 'cannot repair a missed ledger event on re-delivery' do
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
