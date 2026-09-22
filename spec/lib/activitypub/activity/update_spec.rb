require 'rails_helper'

RSpec.describe ActivityPub::Activity::Update do
  let!(:sender) { Fabricate(:account) }

  before do
    stub_request(:get, actor_json[:outbox]).to_return(status: 404)
    stub_request(:get, actor_json[:followers]).to_return(status: 404)
    stub_request(:get, actor_json[:following]).to_return(status: 404)
    stub_request(:get, actor_json[:featured]).to_return(status: 404)

    sender.update!(uri: ActivityPub::TagManager.instance.uri_for(sender))
  end

  let(:modified_sender) do
    sender.tap do |modified_sender|
      modified_sender.display_name = 'Totally modified now'
    end
  end

  let(:actor_json) do
    ActiveModelSerializers::SerializableResource.new(modified_sender, serializer: ActivityPub::ActorSerializer, adapter: ActivityPub::Adapter).as_json
  end

  let(:json) do
    {
      '@context': 'https://www.w3.org/ns/activitystreams',
      id: 'foo',
      type: 'Update',
      actor: ActivityPub::TagManager.instance.uri_for(sender),
      object: actor_json,
    }.with_indifferent_access
  end

  describe '#perform' do
    subject { described_class.new(json, sender) }

    before do
      subject.perform
    end

    it 'updates profile' do
      expect(sender.reload.display_name).to eq 'Totally modified now'
    end
  end

  describe 'remote status updates' do
    let(:sender) do
      Fabricate(
        :account,
        username: 'remote',
        domain: 'example.com',
        protocol: :activitypub,
        uri: 'https://example.com/users/remote',
        inbox_url: 'https://example.com/users/remote/inbox'
      )
    end
    let!(:status) { Fabricate(:status, account: sender, text: 'Original', uri: 'https://example.com/users/remote/statuses/1') }

    def activity_for(**object)
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'https://example.com/activities/1',
        type: 'Update',
        actor: sender.uri,
        object: object,
      }.with_indifferent_access
    end

    it 'dispatches a Note edit' do
      described_class.new(activity_for(id: status.uri, type: 'Note', content: 'Edited note', updated: '2021-09-08T22:39:25Z'), sender, request_id: 'req-1').perform

      expect(status.reload.text).to eq 'Edited note'
      expect(status.edited_at).to be_within(1.second).of(Time.utc(2021, 9, 8, 22, 39, 25))
    end

    it 'dispatches an explicit Question edit' do
      described_class.new(
        activity_for(
          id: status.uri,
          type: 'Question',
          content: 'Edited question',
          updated: '2021-09-08T22:39:25Z',
          oneOf: [{ type: 'Note', name: 'Yes' }, { type: 'Note', name: 'No' }]
        ),
        sender
      ).perform

      expect(status.reload.text).to eq 'Edited question'
      expect(status.poll.options).to eq %w(Yes No)
    end

    it 'applies an implicit Question poll update' do
      poll = Poll.create!(account: sender, status: status, options: %w(Yes No), expires_at: 5.days.from_now, cached_tallies: [0, 0])
      status.update!(poll_id: poll.id)

      described_class.new(
        activity_for(
          id: status.uri,
          type: 'Question',
          content: 'Should be ignored',
          oneOf: [
            { type: 'Note', name: 'Yes', replies: { type: 'Collection', totalItems: 2 } },
            { type: 'Note', name: 'No', replies: { type: 'Collection', totalItems: 1 } },
          ]
        ),
        sender
      ).perform

      expect(status.reload.text).to eq 'Original'
      expect(status.poll.reload.cached_tallies).to eq [2, 1]
      expect(status.edited?).to be false
    end

    it 'rejects an object whose host does not match the actor' do
      described_class.new(activity_for(id: 'https://evil.example/users/remote/statuses/1', type: 'Note', content: 'Nope', updated: '2021-09-08T22:39:25Z'), sender).perform

      expect(status.reload.text).to eq 'Original'
    end

    it 'does nothing when the object is unknown' do
      expect do
        described_class.new(activity_for(id: 'https://example.com/users/remote/statuses/missing', type: 'Note', content: 'Nope', updated: '2021-09-08T22:39:25Z'), sender).perform
      end.to_not raise_error

      expect(status.reload.text).to eq 'Original'
    end

    it 'does not retry an intentional content rejection' do
      previous = Setting.reject_pattern
      Setting.reject_pattern = 'forbidden-phrase'

      expect do
        described_class.new(activity_for(id: status.uri, type: 'Note', content: 'forbidden-phrase', updated: '2021-09-08T22:39:25Z'), sender).perform
      end.to_not raise_error

      expect(status.reload.text).to eq 'Original'
      expect(status.edited?).to be false
    ensure
      Setting.reject_pattern = previous
    end
  end
end
