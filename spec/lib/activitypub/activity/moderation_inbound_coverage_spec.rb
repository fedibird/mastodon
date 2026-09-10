require 'rails_helper'

# PR 6: inbound ActivityPub activities (remote actor -> local target) must be
# recorded in the moderation ledger, since they bypass the hooked local
# services. Recording is idempotent via source_event_key.
RSpec.describe 'Inbound ActivityPub moderation coverage', type: :model do
  let(:remote) { Fabricate(:account, domain: 'remote.example', uri: 'https://remote.example/users/bob', inbox_url: 'https://remote.example/inbox', protocol: :activitypub) }
  let(:local)  { Fabricate(:account) }
  let(:status) { Fabricate(:status, account: local) }

  def last_interaction
    ModerationInteractionEvent.order(:id).last
  end

  describe ActivityPub::Activity::Follow do
    # Locked target keeps this a follow request (no auto-accept / AP delivery).
    let(:locked_local) { Fabricate(:account, locked: true) }
    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://remote.example/activities/follow-1',
        type: 'Follow',
        actor: ActivityPub::TagManager.instance.uri_for(remote),
        object: ActivityPub::TagManager.instance.uri_for(locked_local),
      }.with_indifferent_access
    end

    it 'records an inbound follow interaction from the remote actor' do
      expect { described_class.new(json, remote).perform }.to change(ModerationInteractionEvent, :count).by(1)

      event = last_interaction
      expect(event.event_type).to eq 'follow'
      expect(event.actor_subject.account_id).to eq remote.id
      expect(event.target_subject.account_id).to eq locked_local.id
    end

    it 'does not double-record on re-delivery' do
      described_class.new(json, remote).perform
      expect { described_class.new(json, remote).perform }.to_not change(ModerationInteractionEvent, :count)
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
      expect { described_class.new(favourite_json, remote).perform }.to change(ModerationInteractionEvent, :count).by(1)

      event = last_interaction
      expect(event.event_type).to eq 'favourite'
      expect(event.actor_subject.account_id).to eq remote.id
      expect(event.target_subject.account_id).to eq local.id
      expect(event.status_id).to eq status.id
    end

    it 'does not double-record a repeated favourite' do
      described_class.new(favourite_json, remote).perform
      expect { described_class.new(favourite_json, remote).perform }.to_not change(ModerationInteractionEvent, :count)
    end

    it 'records an inbound reaction toward the local status author' do
      expect { described_class.new(reaction_json, remote).perform }.to change(ModerationInteractionEvent, :count).by(1)

      event = last_interaction
      expect(event.event_type).to eq 'reaction'
      expect(event.actor_subject.account_id).to eq remote.id
      expect(event.target_subject.account_id).to eq local.id
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
      expect { described_class.new(json, remote).perform }.to change(ModerationRejectionEvent, :count).by(1)

      event = ModerationRejectionEvent.order(:id).last
      expect(event.event_type).to eq 'block'
      expect(event.rejector_subject.account_id).to eq remote.id
      expect(event.rejected_subject.account_id).to eq local.id
    end

    it 'does not double-record on re-delivery' do
      described_class.new(json, remote).perform
      expect { described_class.new(json, remote).perform }.to_not change(ModerationRejectionEvent, :count)
    end
  end
end
