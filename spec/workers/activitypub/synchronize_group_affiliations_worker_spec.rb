require 'rails_helper'

RSpec.describe ActivityPub::SynchronizeGroupAffiliationsWorker do
  describe '#perform' do
    it 'returns when the account no longer exists' do
      expect(described_class.new.perform(-1)).to be true
    end

    it 'passes the collection through with string keys' do
      account = Fabricate(:account, username: 'group', domain: 'mitra.example', actor_type: 'Group', uri: 'https://mitra.example/groups/group')
      collection = { 'type' => 'OrderedCollection', 'orderedItems' => [{ 'type' => 'Relationship' }] }
      captured = nil
      service = instance_double(ActivityPub::FetchGroupAffiliationsService)
      allow(service).to receive(:call) { |_account, collection:| captured = collection }
      allow(ActivityPub::FetchGroupAffiliationsService).to receive(:new).and_return(service)

      described_class.new.perform(account.id, 'collection' => collection)

      expect(service).to have_received(:call).with(account, collection: hash_including('type' => 'OrderedCollection'))
      expect(captured['orderedItems'].first['type']).to eq 'Relationship'
    end
  end
end
