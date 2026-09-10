require 'rails_helper'

# PR 6b: inbound ActivityPub Create carrying a mention / reply / quote toward a
# local account is recorded in the moderation ledger. A single chokepoint in
# create_status runs for both a freshly processed status and a re-delivery of an
# existing one, so re-delivery repairs a ledger event a transient recorder
# failure missed. Recording is idempotent via stable source_event_keys.
RSpec.describe ActivityPub::Activity::Create, 'moderation inbound coverage' do
  let(:sender) { Fabricate(:account, domain: 'example.com', uri: 'https://example.com/actor', followers_url: 'https://example.com/followers', protocol: :activitypub, inbox_url: 'https://example.com/inbox') }

  def uri_for(record)
    ActivityPub::TagManager.instance.uri_for(record)
  end

  def json_for(object_json)
    {
      '@context': 'https://www.w3.org/ns/activitystreams',
      id: [uri_for(sender), '#create'].join,
      type: 'Create',
      actor: uri_for(sender),
      object: object_json,
    }.with_indifferent_access
  end

  def last_interaction
    ModerationInteractionEvent.order(:id).last
  end

  before { sender.update(uri: uri_for(sender)) }

  describe 'inbound mention of a local account' do
    let(:recipient) { Fabricate(:account) }
    let(:object_json) do
      {
        id: 'https://example.com/statuses/mention-1',
        type: 'Note',
        content: 'hello there',
        tag: [{ type: 'Mention', href: uri_for(recipient) }],
      }
    end

    it 'records a mention interaction toward the local account' do
      expect { described_class.new(json_for(object_json), sender).perform }.to change(ModerationInteractionEvent, :count).by(1)

      event = last_interaction
      expect(event.event_type).to eq 'mention'
      expect(event.actor_subject.account_id).to eq sender.id
      expect(event.target_subject.account_id).to eq recipient.id
    end

    it 'does not double-record on re-delivery' do
      described_class.new(json_for(object_json), sender).perform
      expect { described_class.new(json_for(object_json), sender).perform }.to_not change(ModerationInteractionEvent, :count)
    end

    it 're-delivery repairs a ledger event missed by a recorder failure' do
      allow(Moderation::EventRecorder).to receive(:record_interaction).and_return(nil)
      described_class.new(json_for(object_json), sender).perform

      expect(sender.statuses.first.mentions.exists?(account: recipient)).to be true
      expect(ModerationInteractionEvent.count).to eq 0

      allow(Moderation::EventRecorder).to receive(:record_interaction).and_call_original
      expect { described_class.new(json_for(object_json), sender).perform }.to change(ModerationInteractionEvent, :count).by(1)
      expect(ModerationInteractionEvent.count).to eq 1
    end
  end

  describe 'inbound reply to a local account' do
    let(:parent_author) { Fabricate(:account) }
    let(:parent)        { Fabricate(:status, account: parent_author) }
    let(:object_json) do
      {
        id: 'https://example.com/statuses/reply-1',
        type: 'Note',
        content: 'replying',
        inReplyTo: uri_for(parent),
        tag: [{ type: 'Mention', href: uri_for(parent_author) }],
      }
    end

    it 'records a reply (not a mention) toward the replied-to local author' do
      expect { described_class.new(json_for(object_json), sender).perform }.to change(ModerationInteractionEvent, :count).by(1)

      event = last_interaction
      expect(event.event_type).to eq 'reply'
      expect(event.actor_subject.account_id).to eq sender.id
      expect(event.target_subject.account_id).to eq parent_author.id
    end

    it 'does not double-record on re-delivery' do
      described_class.new(json_for(object_json), sender).perform
      expect { described_class.new(json_for(object_json), sender).perform }.to_not change(ModerationInteractionEvent, :count)
    end

    it 're-delivery repairs a missed reply event with a stable activity-identity key' do
      allow(Moderation::EventRecorder).to receive(:record_interaction).and_return(nil)
      described_class.new(json_for(object_json), sender).perform

      status = sender.statuses.find_by(uri: object_json[:id])
      expect(status).to be_present
      expect(status.in_reply_to_account_id).to eq parent_author.id
      expect(ModerationInteractionEvent.count).to eq 0

      allow(Moderation::EventRecorder).to receive(:record_interaction).and_call_original
      expect { described_class.new(json_for(object_json), sender).perform }.to change(ModerationInteractionEvent, :count).by(1)

      event = last_interaction
      expect(event.event_type).to eq 'reply'
      expect(event.actor_subject.account_id).to eq sender.id
      expect(event.target_subject.account_id).to eq parent_author.id
      expect(event.source_event_key).to eq "activitypub_reply:#{status.uri}"

      # Ordinary further re-delivery stays at exactly one event.
      expect { described_class.new(json_for(object_json), sender).perform }.to_not change(ModerationInteractionEvent, :count)
    end
  end

  describe 'inbound quote of a local status' do
    let(:quoted_author) { Fabricate(:account) }
    let(:quoted)        { Fabricate(:status, account: quoted_author) }
    let(:object_json) do
      {
        id: 'https://example.com/statuses/quote-1',
        type: 'Note',
        content: 'quoting',
        quoteUri: uri_for(quoted),
      }
    end

    before do
      allow_any_instance_of(ResolveURLService).to receive(:call).and_return(quoted)
      # The quote URL is passed to ProcessStatusReferenceService, which resolves
      # the domain via Node; stub it so the test does not hit the network.
      allow(Node).to receive(:resolve_domain).and_return(nil)
    end

    it 'records a quote interaction toward the quoted local author' do
      expect { described_class.new(json_for(object_json), sender).perform }.to change(ModerationInteractionEvent, :count).by(1)

      event = last_interaction
      expect(event.event_type).to eq 'quote'
      expect(event.actor_subject.account_id).to eq sender.id
      expect(event.target_subject.account_id).to eq quoted_author.id
    end

    it 'does not double-record on re-delivery' do
      described_class.new(json_for(object_json), sender).perform
      expect { described_class.new(json_for(object_json), sender).perform }.to_not change(ModerationInteractionEvent, :count)
    end

    it 're-delivery repairs a missed quote event with a stable activity-identity key' do
      allow(Moderation::EventRecorder).to receive(:record_interaction).and_return(nil)
      described_class.new(json_for(object_json), sender).perform

      status = sender.statuses.find_by(uri: object_json[:id])
      expect(status).to be_present
      expect(status.quote_id).to eq quoted.id
      expect(ModerationInteractionEvent.count).to eq 0

      allow(Moderation::EventRecorder).to receive(:record_interaction).and_call_original
      expect { described_class.new(json_for(object_json), sender).perform }.to change(ModerationInteractionEvent, :count).by(1)

      event = last_interaction
      expect(event.event_type).to eq 'quote'
      expect(event.actor_subject.account_id).to eq sender.id
      expect(event.target_subject.account_id).to eq quoted_author.id
      expect(event.source_event_key).to eq "activitypub_quote:#{status.uri}"

      # Ordinary further re-delivery stays at exactly one event.
      expect { described_class.new(json_for(object_json), sender).perform }.to_not change(ModerationInteractionEvent, :count)
    end
  end
end
