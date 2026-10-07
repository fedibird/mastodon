require 'rails_helper'

RSpec.describe ActivityPub::FetchGroupAffiliationsService do
  let(:group_uri) { 'https://mitra.example/groups/group' }
  let(:collection_url) { 'https://mitra.example/groups/group/affiliations' }
  let(:account) do
    Fabricate(
      :account,
      username: 'group',
      domain: 'mitra.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: group_uri,
      inbox_url: 'https://mitra.example/groups/group/inbox',
      affiliations_url: collection_url
    )
  end
  let(:service) { described_class.new }

  describe '#call' do
    it 'stores a Mitra admin relationship without resolving the subject actor' do
      alice = 'https://unknown.example/users/alice'
      stub_collection(collection_url, ordered_collection([
        relationship(
          subject: alice,
          relationship: 'admin',
          id: 'https://mitra.example/ap/relationships/1'
        ),
      ]))

      expect(ActivityPub::FetchRemoteAccountService).not_to receive(:new)
      expect(ResolveAccountService).not_to receive(:new)

      service.call(account)

      expect(a_request(:get, alice)).not_to have_been_made
      expect(a_request(:get, %r{/.well-known/webfinger})).not_to have_been_made
      stored = account.group_affiliations.find_by!(subject_uri: alice)
      expect(stored.relationship).to eq 'admin'
      expect(stored.affiliation_uri).to eq 'https://mitra.example/ap/relationships/1'
      expect(stored.group_account).to eq account
      expect(account.reload.affiliations_fetched_at).to be_within(2.seconds).of(Time.now.utc)
    end

    it 'preserves a custom relationship token without canonicalizing it' do
      stub_collection(collection_url, ordered_collection([
        relationship(subject: 'https://remote.example/users/alice', relationship: ' trusted-poster ', id: nil),
        relationship(subject: 'https://remote.example/users/bob', relationship: { 'id' => 'Admin' }, id: nil),
        relationship(
          subject: { 'id' => 'https://remote.example/users/carol' },
          relationship: { 'id' => 'https://vocab.example/roles/trusted-poster' },
          id: nil,
          object: :omit,
          attributed_to: :omit
        ),
      ]))

      service.call(account)

      expect(account.group_affiliations.pluck(:subject_uri, :relationship, :affiliation_uri)).to contain_exactly(
        ['https://remote.example/users/alice', 'trusted-poster', nil],
        ['https://remote.example/users/bob', 'Admin', nil],
        ['https://remote.example/users/carol', 'https://vocab.example/roles/trusted-poster', nil]
      )
    end

    it 'stores several roles for one subject and ignores duplicate pairs' do
      alice = 'https://remote.example/users/alice'
      stub_collection(collection_url, ordered_collection([
        relationship(subject: alice, relationship: 'admin', id: 'https://mitra.example/ap/relationships/1'),
        relationship(subject: alice, relationship: 'admin', id: 'https://mitra.example/ap/relationships/1-dup'),
        relationship(subject: alice, relationship: 'trusted-poster', id: nil),
      ]))

      service.call(account)

      expect(account.group_affiliations.pluck(:subject_uri, :relationship, :affiliation_uri)).to contain_exactly(
        [alice, 'admin', 'https://mitra.example/ap/relationships/1'],
        [alice, 'trusted-poster', nil]
      )
    end

    it 'accepts a Relationship type array and both collection item keys' do
      stub_collection(collection_url, collection_document('Collection', 'items' => [
        relationship(subject: 'https://remote.example/users/alice', relationship: 'admin').merge('type' => ['Relationship', 'Object']),
      ]))

      service.call(account)

      expect(account.group_affiliations.pluck(:relationship)).to eq ['admin']
    end

    it 'reads an inline ordered collection without fetching it again' do
      inline = ordered_collection([
        relationship(subject: 'https://remote.example/users/alice', relationship: 'admin', id: 'https://mitra.example/ap/relationships/9'),
      ])
      inline.delete('@context')
      account.update_columns(affiliations_url: nil)

      service.call(account, collection: inline)

      expect(a_request(:get, /affiliations/)).not_to have_been_made
      expect(account.group_affiliations.pluck(:subject_uri, :affiliation_uri)).to eq [
        ['https://remote.example/users/alice', 'https://mitra.example/ap/relationships/9'],
      ]
    end

    it 'follows the first page and subsequent pages on the group host' do
      first = 'https://mitra.example/groups/group/affiliations?page=1'
      nxt = 'https://mitra.example/groups/group/affiliations?page=2'
      stub_collection(collection_url, ordered_collection([], 'first' => first))
      stub_collection(first, ordered_page([
        relationship(subject: 'https://remote.example/users/alice', relationship: 'admin'),
      ], 'next' => nxt))
      stub_collection(nxt, ordered_page([
        relationship(subject: 'https://remote.example/users/bob', relationship: 'trusted-poster'),
      ]))

      service.call(account)

      expect(account.group_affiliations.pluck(:subject_uri, :relationship)).to contain_exactly(
        ['https://remote.example/users/alice', 'admin'],
        ['https://remote.example/users/bob', 'trusted-poster']
      )
    end

    it 'clears cached rows when the collection is authoritatively empty' do
      cache_affiliation!
      stub_collection(collection_url, ordered_collection([]))

      service.call(account)

      expect(account.group_affiliations).to be_empty
      expect(account.reload.affiliations_fetched_at).to be_within(2.seconds).of(Time.now.utc)
    end

    it 'skips malformed items and relationships owned by another group' do
      stub_collection(collection_url, ordered_collection([
        { 'type' => 'Note', 'subject' => 'https://remote.example/users/nope', 'relationship' => 'admin' },
        relationship(subject: ' ', relationship: 'admin'),
        relationship(subject: 'https://remote.example/users/foreign-object', relationship: 'admin', object: 'https://other.example/groups/other'),
        relationship(subject: 'https://remote.example/users/foreign-attribution', relationship: 'admin', attributed_to: 'https://other.example/groups/other'),
        relationship(subject: 'https://remote.example/users/alice', relationship: 'admin', id: 'https://mitra.example/ap/relationships/1'),
      ]))

      service.call(account)

      expect(account.group_affiliations.pluck(:subject_uri)).to eq ['https://remote.example/users/alice']
    end

    it 'keeps the previous snapshot when the payload is not JSON' do
      cached = cache_affiliation!
      stub_request(:get, collection_url).to_return(status: 200, body: '{', headers: { 'Content-Type' => 'application/activity+json' })

      service.call(account)

      expect(account.group_affiliations.pluck(:id)).to eq [cached.id]
      expect(account.reload.affiliations_fetched_at).to eq cached_stamp
    end

    it 'keeps the previous snapshot when fetching fails' do
      cached = cache_affiliation!
      stub_request(:get, collection_url).to_timeout

      service.call(account)

      expect(account.group_affiliations.pluck(:subject_uri)).to eq [cached.subject_uri]
      expect(account.reload.affiliations_fetched_at).to eq cached_stamp
    end

    it 'keeps the previous snapshot when the document context is unsupported' do
      cached = cache_affiliation!
      stub_collection(collection_url, { 'type' => 'OrderedCollection', 'orderedItems' => [] })

      service.call(account)

      expect(account.group_affiliations.pluck(:id)).to eq [cached.id]
      expect(account.reload.affiliations_fetched_at).to eq cached_stamp
    end

    it 'keeps the previous snapshot when the item limit is exceeded' do
      cached = cache_affiliation!
      stub_const('ActivityPub::FetchGroupAffiliationsService::MAX_ITEMS', 1)
      stub_collection(collection_url, ordered_collection([
        relationship(subject: 'https://remote.example/users/alice', relationship: 'admin'),
        relationship(subject: 'https://remote.example/users/bob', relationship: 'admin'),
      ]))

      service.call(account)

      expect(account.group_affiliations.pluck(:subject_uri)).to eq [cached.subject_uri]
      expect(account.reload.affiliations_fetched_at).to eq cached_stamp
    end

    it 'keeps the previous snapshot when pagination exceeds the page limit' do
      cached = cache_affiliation!
      first = 'https://mitra.example/groups/group/affiliations?page=1'
      stub_const('ActivityPub::FetchGroupAffiliationsService::MAX_PAGES', 1)
      stub_collection(collection_url, ordered_collection([], 'first' => first))
      stub_collection(first, ordered_page([
        relationship(subject: 'https://remote.example/users/alice', relationship: 'admin'),
      ]))

      service.call(account)

      expect(account.group_affiliations.pluck(:subject_uri)).to eq [cached.subject_uri]
      expect(account.reload.affiliations_fetched_at).to eq cached_stamp
    end

    it 'does not follow a next page on another host or replace the snapshot' do
      cached = cache_affiliation!
      first = 'https://mitra.example/groups/group/affiliations?page=1'
      evil = 'https://evil.example/affiliations?page=2'
      stub_collection(collection_url, ordered_collection([], 'first' => first))
      stub_collection(first, ordered_page([
        relationship(subject: 'https://remote.example/users/alice', relationship: 'admin'),
      ], 'next' => evil))

      service.call(account)

      expect(a_request(:get, evil)).not_to have_been_made
      expect(account.group_affiliations.pluck(:subject_uri)).to eq [cached.subject_uri]
      expect(account.reload.affiliations_fetched_at).to eq cached_stamp
    end

    it 'does not fetch an affiliations URL on a different host' do
      cached = cache_affiliation!
      account.update_columns(affiliations_url: 'https://evil.example/affiliations')

      service.call(account)

      expect(a_request(:get, 'https://evil.example/affiliations')).not_to have_been_made
      expect(account.group_affiliations.pluck(:id)).to eq [cached.id]
    end

    it 'does nothing for a local group, a non-group, or a suspended group' do
      local_group = Fabricate(:account, username: 'localgroup', actor_type: 'Group', affiliations_url: collection_url)
      person = Fabricate(:account, username: 'alice', domain: 'mitra.example', actor_type: 'Person', uri: 'https://mitra.example/users/alice', affiliations_url: collection_url)
      account.update_columns(suspended_at: Time.now.utc)
      [local_group, person, account].each do |target|
        GroupAffiliation.create!(group_account: target, subject_uri: 'https://remote.example/users/alice', relationship: 'admin')
      end

      [local_group, person, account].each { |target| service.call(target) }

      expect(a_request(:get, collection_url)).not_to have_been_made
      expect(GroupAffiliation.count).to eq 3
    end

    it 'signs the collection fetch with a local follower when one exists' do
      follower = Fabricate(:account)
      Fabricate(:follow, account: follower, target_account: account)
      document = ordered_collection([])
      allow(service).to receive(:fetch_resource_without_id_validation).and_return(document)

      service.call(account)

      expect(service).to have_received(:fetch_resource_without_id_validation).with(collection_url, follower, true)
    end

    it 'fetches without a follower when the group has none' do
      document = ordered_collection([])
      allow(service).to receive(:fetch_resource_without_id_validation).and_return(document)

      service.call(account)

      expect(service).to have_received(:fetch_resource_without_id_validation).with(collection_url, nil, true)
    end
  end

  def cache_affiliation!
    account.update_columns(affiliations_fetched_at: cached_stamp)
    GroupAffiliation.create!(
      group_account: account,
      subject_uri: 'https://remote.example/users/old',
      relationship: 'admin',
      affiliation_uri: 'https://mitra.example/ap/relationships/old'
    )
  end

  def cached_stamp
    Time.utc(2026, 1, 1, 0, 0, 0)
  end

  def ordered_collection(items, extra = {})
    collection_document('OrderedCollection', extra.merge('orderedItems' => items))
  end

  def ordered_page(items, extra = {})
    collection_document('OrderedCollectionPage', extra.merge('orderedItems' => items))
  end

  def collection_document(type, extra = {})
    {
      '@context' => 'https://www.w3.org/ns/activitystreams',
      'type' => type,
    }.merge(extra)
  end

  def relationship(subject:, relationship:, id: 'https://mitra.example/ap/relationships/1', object: group_uri, attributed_to: group_uri)
    item = {
      'type' => 'Relationship',
      'subject' => subject,
      'relationship' => relationship,
    }
    item['id'] = id unless id.nil?
    item['object'] = object unless object == :omit
    item['attributedTo'] = attributed_to unless attributed_to == :omit
    item
  end

  def stub_collection(url, body)
    stub_request(:get, url).to_return(
      status: 200,
      body: Oj.dump(body),
      headers: { 'Content-Type' => 'application/activity+json' }
    )
  end
end
