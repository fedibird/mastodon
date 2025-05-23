require 'rails_helper'

RSpec.describe ActivityPub::ProcessAccountService, type: :service do
  subject { described_class.new }

  context 'with property values, an avatar, and a profile header' do
    let(:payload) do
      {
        id: 'https://foo.test',
        type: 'Actor',
        inbox: 'https://foo.test/inbox',
        attachment: [
          { type: 'PropertyValue', name: 'Pronouns', value: 'They/them' },
          { type: 'PropertyValue', name: 'Occupation', value: 'Unit test' },
          { type: 'PropertyValue', name: 'non-string', value: ['foo', 'bar'] },
        ],
        image: {
          type: 'Image',
          mediaType: 'image/png',
          url: 'https://foo.test/image.png',
        },
        icon: {
          type: 'Image',
          url: [
            {
              mediaType: 'image/png',
              href: 'https://foo.test/icon.png',
            },
          ],
        },
      }.with_indifferent_access
    end

    before do
      stub_request(:get, 'https://foo.test/image.png').to_return(request_fixture('avatar.txt'))
      stub_request(:get, 'https://foo.test/icon.png').to_return(request_fixture('avatar.txt'))
    end

    it 'parses property values, avatar and profile header as expected' do
      account = subject.call('alice', 'example.com', payload)

      expect(account.fields)
        .to be_an(Array)
        .and have_attributes(size: 2)
      expect(account.fields.first)
        .to be_an(Account::Field)
        .and have_attributes(
          name: eq('Pronouns'),
          value: eq('They/them')
        )
      expect(account.fields.last)
        .to be_an(Account::Field)
        .and have_attributes(
          name: eq('Occupation'),
          value: eq('Unit test')
        )
      expect(account).to have_attributes(
        avatar_remote_url: 'https://foo.test/icon.png',
        header_remote_url: 'https://foo.test/image.png'
      )
    end
  end

  context 'identity proofs' do
    let(:payload) do
      {
        id: 'https://foo.test',
        type: 'Actor',
        inbox: 'https://foo.test/inbox',
        attachment: [
          { type: 'IdentityProof', name: 'Alice', signatureAlgorithm: 'keybase', signatureValue: 'a' * 66 },
        ],
      }.with_indifferent_access
    end

    it 'parses out of attachment' do
      allow(ProofProvider::Keybase::Worker).to receive(:perform_async)

      account = subject.call('alice', 'example.com', payload)

      expect(account.identity_proofs.count).to eq 1

      proof = account.identity_proofs.first

      expect(proof.provider).to eq 'keybase'
      expect(proof.provider_username).to eq 'Alice'
      expect(proof.token).to eq 'a' * 66
    end

    it 'removes no longer present proofs' do
      allow(ProofProvider::Keybase::Worker).to receive(:perform_async)

      account   = Fabricate(:account, username: 'alice', domain: 'example.com')
      old_proof = Fabricate(:account_identity_proof, account: account, provider: 'keybase', provider_username: 'Bob', token: 'b' * 66)

      subject.call('alice', 'example.com', payload)

      expect(account.identity_proofs.count).to eq 1
      expect(account.identity_proofs.find_by(id: old_proof.id)).to be_nil
    end

    it 'queues a validity check on the proof' do
      allow(ProofProvider::Keybase::Worker).to receive(:perform_async)
      account = subject.call('alice', 'example.com', payload)
      expect(ProofProvider::Keybase::Worker).to have_received(:perform_async)
    end
  end

  context 'with inlined feature collection' do
    let(:payload) do
      {
        id: 'https://foo.test',
        type: 'Actor',
        inbox: 'https://foo.test/inbox',
        featured: {
          type: 'OrderedCollection',
          orderedItems: ['https://example.com/statuses/1'],
        },
      }.deep_stringify_keys
    end

    it 'queues featured collection synchronization', :aggregate_failures do
      account = subject.call('alice', 'example.com', payload)

      expect(account.featured_collection_url).to eq ''
      expect(ActivityPub::SynchronizeFeaturedCollectionWorker).to have_enqueued_sidekiq_job(account.id, { 'hashtag' => true, 'request_id' => anything, 'collection' => payload['featured'] })
    end
  end

  context 'when account is not suspended' do
    let!(:account) { Fabricate(:account, username: 'alice', domain: 'example.com') }

    let(:payload) do
      {
        id: 'https://foo.test',
        type: 'Actor',
        inbox: 'https://foo.test/inbox',
        suspended: true,
      }.with_indifferent_access
    end

    before do
      allow(Admin::SuspensionWorker).to receive(:perform_async)
    end

    subject { described_class.new.call('alice', 'example.com', payload) }

    it 'suspends account remotely' do
      expect(subject.suspended?).to be true
      expect(subject.suspension_origin_remote?).to be true
    end

    it 'queues suspension worker' do
      subject
      expect(Admin::SuspensionWorker).to have_received(:perform_async)
    end
  end

  context 'when account is suspended' do
    let!(:account) { Fabricate(:account, username: 'alice', domain: 'example.com', display_name: '') }

    let(:payload) do
      {
        id: 'https://foo.test',
        type: 'Actor',
        inbox: 'https://foo.test/inbox',
        suspended: false,
        name: 'Hoge',
      }.with_indifferent_access
    end

    before do
      allow(Admin::UnsuspensionWorker).to receive(:perform_async)

      account.suspend!(origin: suspension_origin)
    end

    subject { described_class.new.call('alice', 'example.com', payload) }

    context 'locally' do
      let(:suspension_origin) { :local }

      it 'does not unsuspend it' do
        expect(subject.suspended?).to be true
      end

      it 'does not update any attributes' do
        expect(subject.display_name).to_not eq 'Hoge'
      end
    end

    context 'remotely' do
      let(:suspension_origin) { :remote }

      it 'unsuspends it' do
        expect(subject.suspended?).to be false
      end

      it 'queues unsuspension worker' do
        subject
        expect(Admin::UnsuspensionWorker).to have_received(:perform_async)
      end

      it 'updates attributes' do
        expect(subject.display_name).to eq 'Hoge'
      end
    end
  end
end
