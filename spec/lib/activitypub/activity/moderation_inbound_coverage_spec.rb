require 'rails_helper'

# PR 6: inbound ActivityPub activities (remote actor -> local target) are
# recorded in the moderation ledger, since they bypass the hooked local
# services. Recording is idempotent via source_event_key, and — because
# recording is failure-tolerant — a later re-delivery must REPAIR a ledger
# event that a transient recorder failure missed on an earlier delivery.
RSpec.describe 'Inbound ActivityPub moderation coverage', type: :model do
  let(:remote) { Fabricate(:account, domain: 'remote.example', uri: 'https://remote.example/users/bob', inbox_url: 'https://remote.example/inbox', protocol: :activitypub) }
  let(:local)  { Fabricate(:account) }
  let(:status) { Fabricate(:status, account: local) }

  def deliver(klass, json)
    klass.new(json, remote).perform
  end

  describe ActivityPub::Activity::Follow do
    # Unlocked target => auto-accepted: the surviving durable record is the
    # Follow (the FollowRequest is destroyed by authorization). Stub AP delivery
    # so the outbound Accept does not hit the network.
    before { allow(ActivityPub::DeliveryWorker).to receive(:perform_async) }

    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/follow-1',
        type: 'Follow',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: ActivityPub::TagManager.instance.uri_for(local),
      }.with_indifferent_access
    end

    it 'records an inbound follow interaction from the remote actor' do
      expect { deliver(described_class, json) }.to change(ModerationInteractionEvent, :count).by(1)

      event = ModerationInteractionEvent.order(:id).last
      expect(event.event_type).to eq 'follow'
      expect(event.actor_subject.account_id).to eq remote.id
      expect(event.target_subject.account_id).to eq local.id
      expect(remote.following?(local)).to be true
    end

    it 'does not double-record on ordinary re-delivery' do
      deliver(described_class, json)
      expect { deliver(described_class, json) }.to_not change(ModerationInteractionEvent, :count)
    end

    it 're-delivery repairs a ledger event missed by a transient recorder failure' do
      allow(Moderation::EventRecorder).to receive(:record_interaction).and_return(nil)
      deliver(described_class, json)

      expect(remote.following?(local)).to be true
      expect(ModerationInteractionEvent.count).to eq 0

      allow(Moderation::EventRecorder).to receive(:record_interaction).and_call_original
      expect { deliver(described_class, json) }.to change(ModerationInteractionEvent, :count).by(1)
      expect(ModerationInteractionEvent.count).to eq 1
    end

    context 'with a locked target (pending -> accepted lifecycle)' do
      let(:locked) { Fabricate(:account, locked: true) }
      let(:locked_json) do
        json.merge(object: ActivityPub::TagManager.instance.uri_for(locked)).with_indifferent_access
      end

      it 'keeps exactly one follow event across the FollowRequest -> Follow conversion on re-delivery' do
        # 1. Inbound follow to a locked account -> pending request -> one event.
        expect { deliver(described_class, locked_json) }.to change(ModerationInteractionEvent, :count).by(1)
        request = FollowRequest.find_by(account: remote, target_account: locked)
        expect(request).to be_present

        # 2. Local user accepts: the surviving relationship is now a Follow.
        request.authorize!
        expect(remote.following?(locked)).to be true
        expect(FollowRequest.find_by(account: remote, target_account: locked)).to be_nil

        # 3. Same ActivityPub Follow re-delivered -> existing-Follow branch.
        expect { deliver(described_class, locked_json) }.to_not change(ModerationInteractionEvent, :count)
        expect(ModerationInteractionEvent.where(actor_subject: ModerationSubject.find_by(account_id: remote.id)).count).to eq 1
      end

      it 'repairs a missed ledger event while the request is still pending' do
        allow(Moderation::EventRecorder).to receive(:record_interaction).and_return(nil)
        deliver(described_class, locked_json)

        expect(remote.requested?(locked)).to be true
        expect(ModerationInteractionEvent.count).to eq 0

        allow(Moderation::EventRecorder).to receive(:record_interaction).and_call_original
        expect { deliver(described_class, locked_json) }.to change(ModerationInteractionEvent, :count).by(1)
        expect(ModerationInteractionEvent.count).to eq 1
      end
    end
  end

  describe ActivityPub::Activity::Like do
    let(:favourite_json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/like-1',
        type: 'Like',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: ActivityPub::TagManager.instance.uri_for(status),
      }.with_indifferent_access
    end

    let(:reaction_json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/react-1',
        type: 'EmojiReact',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: ActivityPub::TagManager.instance.uri_for(status),
        content: '👍',
      }.with_indifferent_access
    end

    it 'records an inbound favourite toward the local status author' do
      expect { deliver(described_class, favourite_json) }.to change(ModerationInteractionEvent, :count).by(1)

      event = ModerationInteractionEvent.order(:id).last
      expect(event.event_type).to eq 'favourite'
      expect(event.actor_subject.account_id).to eq remote.id
      expect(event.target_subject.account_id).to eq local.id
      expect(event.status_id).to eq status.id
    end

    it 'does not double-record a repeated favourite' do
      deliver(described_class, favourite_json)
      expect { deliver(described_class, favourite_json) }.to_not change(ModerationInteractionEvent, :count)
    end

    it 'favourite re-delivery repairs a ledger event missed by a recorder failure' do
      allow(Moderation::EventRecorder).to receive(:record_interaction).and_return(nil)
      deliver(described_class, favourite_json)

      expect(remote.favourited?(status)).to be true
      expect(ModerationInteractionEvent.count).to eq 0

      allow(Moderation::EventRecorder).to receive(:record_interaction).and_call_original
      expect { deliver(described_class, favourite_json) }.to change(ModerationInteractionEvent, :count).by(1)
      expect(ModerationInteractionEvent.count).to eq 1
    end

    it 'records an inbound reaction toward the local status author' do
      expect { deliver(described_class, reaction_json) }.to change(ModerationInteractionEvent, :count).by(1)

      event = ModerationInteractionEvent.order(:id).last
      expect(event.event_type).to eq 'reaction'
      expect(event.actor_subject.account_id).to eq remote.id
      expect(event.target_subject.account_id).to eq local.id
    end

    it 'reaction re-delivery repairs a ledger event missed by a recorder failure' do
      allow(Moderation::EventRecorder).to receive(:record_interaction).and_return(nil)
      deliver(described_class, reaction_json)

      expect(status.emoji_reactions.exists?(account: remote)).to be true
      expect(ModerationInteractionEvent.count).to eq 0

      allow(Moderation::EventRecorder).to receive(:record_interaction).and_call_original
      expect { deliver(described_class, reaction_json) }.to change(ModerationInteractionEvent, :count).by(1)
      expect(ModerationInteractionEvent.count).to eq 1
    end
  end

  describe ActivityPub::Activity::Block do
    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/block-1',
        type: 'Block',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: ActivityPub::TagManager.instance.uri_for(local),
      }.with_indifferent_access
    end

    it 'records an inbound block rejection from the remote actor' do
      expect { deliver(described_class, json) }.to change(ModerationRejectionEvent, :count).by(1)

      event = ModerationRejectionEvent.order(:id).last
      expect(event.event_type).to eq 'block'
      expect(event.rejector_subject.account_id).to eq remote.id
      expect(event.rejected_subject.account_id).to eq local.id
    end

    it 'does not double-record on ordinary re-delivery' do
      deliver(described_class, json)
      expect { deliver(described_class, json) }.to_not change(ModerationRejectionEvent, :count)
    end

    it 're-delivery repairs a ledger event missed by a transient recorder failure' do
      allow(Moderation::EventRecorder).to receive(:record_rejection).and_return(nil)
      deliver(described_class, json)

      expect(remote.blocking?(local)).to be true
      expect(ModerationRejectionEvent.count).to eq 0

      allow(Moderation::EventRecorder).to receive(:record_rejection).and_call_original
      expect { deliver(described_class, json) }.to change(ModerationRejectionEvent, :count).by(1)
      expect(ModerationRejectionEvent.count).to eq 1
    end
  end
end
