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

  context 'with a memorial flag' do
    let(:payload) do
      {
        id: 'https://foo.test',
        type: 'Actor',
        inbox: 'https://foo.test/inbox',
        memorial: memorial,
      }.with_indifferent_access
    end

    context 'when memorial is true' do
      let(:memorial) { true }

      it 'stores the remote account as memorial' do
        account = Fabricate(:account, username: 'alice', domain: 'example.com', memorial: false)

        subject.call('alice', 'example.com', payload)

        expect(account.reload).to be_memorial
      end
    end

    context 'when memorial is false' do
      let(:memorial) { false }

      it 'clears a previously memorial remote account' do
        account = Fabricate(:account, username: 'alice', domain: 'example.com', memorial: true)

        subject.call('alice', 'example.com', payload)

        expect(account.reload).not_to be_memorial
      end
    end

    context 'when memorial is missing' do
      let(:payload) do
        {
          id: 'https://foo.test',
          type: 'Actor',
          inbox: 'https://foo.test/inbox',
        }.with_indifferent_access
      end

      it 'clears a previously memorial remote account' do
        account = Fabricate(:account, username: 'alice', domain: 'example.com', memorial: true)

        subject.call('alice', 'example.com', payload)

        expect(account.reload).not_to be_memorial
      end
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

  context 'with a remote group affiliations collection' do
    after do
      ActivityPub::SynchronizeGroupAffiliationsWorker.clear
    end

    let(:uri) { 'https://foo.test/groups/g' }
    let(:affiliations_url) { 'https://foo.test/groups/g/affiliations' }
    let!(:account) do
      Fabricate(
        :account,
        username: 'group',
        domain: 'foo.test',
        actor_type: 'Group',
        protocol: :activitypub,
        uri: uri
      )
    end

    it 'stores the collection URL and queues a background sync' do
      payload = group_payload(affiliations: affiliations_url)

      Sidekiq::Testing.fake! do
        subject.call('group', 'foo.test', payload)
        expect(ActivityPub::SynchronizeGroupAffiliationsWorker).to have_enqueued_sidekiq_job(account.id, {})
      end

      expect(account.reload.affiliations_url).to eq affiliations_url
    end

    it 'passes an inline collection without the rest of the actor document' do
      collection = {
        'id' => affiliations_url,
        'type' => 'OrderedCollection',
        'orderedItems' => [],
      }
      payload = group_payload(affiliations: collection)

      Sidekiq::Testing.fake! do
        subject.call('group', 'foo.test', payload)
        expect(ActivityPub::SynchronizeGroupAffiliationsWorker).to have_enqueued_sidekiq_job(account.id, { 'collection' => collection })
      end

      expect(account.reload.affiliations_url).to eq affiliations_url
    end

    it 'stores a collection reference given as an id object' do
      payload = group_payload(affiliations: { 'id' => affiliations_url })

      Sidekiq::Testing.fake! do
        subject.call('group', 'foo.test', payload)
        expect(ActivityPub::SynchronizeGroupAffiliationsWorker).to have_enqueued_sidekiq_job(account.id, {})
      end

      expect(account.reload.affiliations_url).to eq affiliations_url
    end

    it 'ignores affiliations on a non-group and drops a previous group cache' do
      GroupAffiliation.create!(group_account: account, subject_uri: 'https://remote.example/users/alice', relationship: 'admin')
      account.update_columns(affiliations_url: affiliations_url, affiliations_fetched_at: Time.utc(2026, 1, 1))
      payload = group_payload(type: 'Person', affiliations: affiliations_url)

      Sidekiq::Testing.fake! do
        subject.call('group', 'foo.test', payload)
        expect(ActivityPub::SynchronizeGroupAffiliationsWorker.jobs).to be_empty
      end

      expect(account.reload.actor_type).to eq 'Person'
      expect(account.affiliations_url).to be_nil
      expect(account.affiliations_fetched_at).to be_nil
      expect(account.group_affiliations).to be_empty
    end

    it 'does not change affiliation metadata during an only_key refresh' do
      account.update_columns(affiliations_url: affiliations_url, affiliations_fetched_at: Time.utc(2026, 1, 1))
      payload = group_payload(affiliations: 'https://foo.test/groups/g/other')

      Sidekiq::Testing.fake! do
        subject.call('group', 'foo.test', payload, only_key: true)
        expect(ActivityPub::SynchronizeGroupAffiliationsWorker.jobs).to be_empty
      end

      expect(account.reload.affiliations_url).to eq affiliations_url
      expect(account.affiliations_fetched_at).to eq Time.utc(2026, 1, 1)
    end

    it 'clears the cached collection when the actor withdraws affiliations' do
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: 'https://remote.example/users/alice',
        relationship: 'admin',
        affiliation_uri: 'https://foo.test/relationships/1'
      )
      account.update_columns(affiliations_url: affiliations_url, affiliations_fetched_at: Time.utc(2026, 1, 1))

      Sidekiq::Testing.fake! do
        subject.call('group', 'foo.test', group_payload)
        expect(ActivityPub::SynchronizeGroupAffiliationsWorker.jobs).to be_empty
      end

      expect(a_request(:get, affiliations_url)).not_to have_been_made
      expect(account.reload.affiliations_url).to be_nil
      expect(account.affiliations_fetched_at).to be_nil
      expect(account.group_affiliations).to be_empty
    end

    it 'does not queue affiliation sync while the group is suspended' do
      account.update_columns(affiliations_url: affiliations_url, suspended_at: Time.now.utc, suspension_origin: Account.suspension_origins[:local])
      payload = group_payload(affiliations: 'https://foo.test/groups/g/other')

      Sidekiq::Testing.fake! do
        subject.call('group', 'foo.test', payload)
        expect(ActivityPub::SynchronizeGroupAffiliationsWorker.jobs).to be_empty
      end

      expect(account.reload.affiliations_url).to eq affiliations_url
    end

    def group_payload(type: 'Group', affiliations: nil)
      payload = {
        id: uri,
        type: type,
        inbox: 'https://foo.test/inbox',
      }
      payload[:affiliations] = affiliations unless affiliations.nil?
      payload.with_indifferent_access
    end
  end
end
