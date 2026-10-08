# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingContext::RevalidateGroupEvidenceService do
  let(:uri) { 'https://mitra.example/users/group' }
  let(:old_url) { 'https://mitra.example/users/group/affiliations' }
  let(:new_url) { 'https://mitra.example/users/group/affiliations-v2' }
  let(:account) do
    Fabricate(
      :account,
      username: 'group',
      domain: 'mitra.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: uri,
      inbox_url: 'https://mitra.example/users/group/inbox',
      affiliations_url: old_url,
      can_create_affiliation: 'member',
      can_view_affiliation: 'member',
      permission_definitions_fetched_at: Time.utc(2026, 1, 1),
      affiliations_fetched_at: Time.utc(2026, 1, 1)
    )
  end
  let(:service) { described_class.new }

  before do
    GroupAffiliation.create!(
      group_account: account,
      subject_uri: 'https://remote.example/users/old',
      relationship: 'member'
    )
  end

  it 'updates canCreate and canView from the actor refresh and then the affiliations collection' do
    fetch_actor(canCreate: 'trusted-poster', canView: 'admin', affiliations: new_url)
    stub_collection(new_url, relationship_collection('https://remote.example/users/alice', 'trusted-poster'))

    result = nil
    Sidekiq::Testing.fake! do
      result = service.call(account)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker.jobs).to be_empty
    end

    account.reload
    expect(result.state).to eq 'completed'
    expect(result.actor).to eq 'refreshed'
    expect(result.affiliations).to eq 'refreshed'
    expect(account.can_create_affiliation).to eq 'trusted-poster'
    expect(account.can_view_affiliation).to eq 'admin'
    expect(account.permission_definitions_fetched_at).to be > Time.utc(2026, 1, 1)
    expect(account.affiliations_url).to eq new_url
    expect(account.group_affiliations.pluck(:subject_uri, :relationship)).to eq [['https://remote.example/users/alice', 'trusted-poster']]
    expect(account.affiliations_fetched_at).to be > Time.utc(2026, 1, 1)
    expect(a_request(:get, old_url)).not_to have_been_made
  end

  it 'keeps the definition snapshot when the actor refresh fails and still refreshes affiliations' do
    allow(ActivityPub::FetchRemoteAccountService).to receive(:new).and_return(instance_double(ActivityPub::FetchRemoteAccountService, call: nil))
    stub_collection(old_url, relationship_collection('https://remote.example/users/alice', 'admin'))

    result = service.call(account)

    account.reload
    expect(result.state).to eq 'partial'
    expect(result.actor).to eq 'failed'
    expect(result.affiliations).to eq 'refreshed'
    expect(account.can_create_affiliation).to eq 'member'
    expect(account.can_view_affiliation).to eq 'member'
    expect(account.permission_definitions_fetched_at).to eq Time.utc(2026, 1, 1)
    expect(account.group_affiliations.pluck(:relationship)).to eq ['admin']
  end

  it 'keeps affiliation rows and fetched_at when the collection fetch fails' do
    fetch_actor(canCreate: 'none', canView: 'member', affiliations: old_url)
    stub_request(:get, old_url).to_timeout

    result = service.call(account)

    account.reload
    expect(result.state).to eq 'partial'
    expect(result.actor).to eq 'refreshed'
    expect(result.affiliations).to eq 'failed'
    expect(account.can_create_affiliation).to eq 'none'
    expect(account.affiliations_fetched_at).to eq Time.utc(2026, 1, 1)
    expect(account.group_affiliations.pluck(:relationship)).to eq ['member']
  end

  it 'stores a successful empty collection as a fresh snapshot' do
    fetch_actor(canCreate: 'none', canView: nil, affiliations: old_url)
    stub_collection(old_url, {
      '@context' => 'https://www.w3.org/ns/activitystreams',
      'type' => 'OrderedCollection',
      'orderedItems' => [],
    })

    result = service.call(account)

    account.reload
    expect(result).to have_attributes(state: 'completed', actor: 'refreshed', affiliations: 'refreshed')
    expect(account.group_affiliations).to be_empty
    expect(account.affiliations_fetched_at).to be > Time.utc(2026, 1, 1)
  end

  it 'withdraws the affiliation cache when the actor removes the collection' do
    fetch_actor(canCreate: 'admin', canView: 'member', affiliations: nil)
    expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)

    result = nil
    Sidekiq::Testing.fake! do
      result = service.call(account)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker.jobs).to be_empty
    end

    account.reload
    expect(result).to have_attributes(state: 'completed', actor: 'refreshed', affiliations: 'skipped')
    expect(account.affiliations_url).to be_nil
    expect(account.affiliations_fetched_at).to be_nil
    expect(account.group_affiliations).to be_empty
  end

  it 'refreshes an inline collection that has no URL' do
    fetch_actor(canCreate: 'member', affiliations: {
      'type' => 'OrderedCollection',
      'orderedItems' => [
        {
          'type' => 'Relationship',
          'subject' => 'https://remote.example/users/inline',
          'relationship' => 'admin',
          'object' => uri,
        },
      ],
    })

    result = nil
    Sidekiq::Testing.fake! do
      result = service.call(account)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker.jobs).to be_empty
    end

    account.reload
    expect(result).to have_attributes(state: 'completed', actor: 'refreshed', affiliations: 'refreshed')
    expect(account.affiliations_url).to be_nil
    expect(account.group_affiliations.pluck(:subject_uri, :relationship)).to eq [['https://remote.example/users/inline', 'admin']]
    expect(account.affiliations_fetched_at).to be > Time.utc(2026, 1, 1)
    expect(a_request(:get, old_url)).not_to have_been_made
  end

  it 'stores an inline empty collection as a fresh snapshot' do
    fetch_actor(canCreate: 'none', affiliations: {
      'type' => 'OrderedCollection',
      'orderedItems' => [],
    })

    result = service.call(account)

    account.reload
    expect(result).to have_attributes(state: 'completed', actor: 'refreshed', affiliations: 'refreshed')
    expect(account.affiliations_url).to be_nil
    expect(account.group_affiliations).to be_empty
    expect(account.affiliations_fetched_at).to be > Time.utc(2026, 1, 1)
  end

  it 'uses an inline collection with an id and stores that id as the URL' do
    fetch_actor(canCreate: 'member', affiliations: {
      'id' => new_url,
      'type' => 'OrderedCollection',
      'orderedItems' => [
        {
          'type' => 'Relationship',
          'subject' => 'https://remote.example/users/inline',
          'relationship' => 'trusted-poster',
          'object' => uri,
        },
      ],
    })

    result = service.call(account)

    account.reload
    expect(result).to have_attributes(state: 'completed', affiliations: 'refreshed')
    expect(account.affiliations_url).to eq new_url
    expect(account.group_affiliations.pluck(:relationship)).to eq ['trusted-poster']
    expect(a_request(:get, new_url)).not_to have_been_made
    expect(a_request(:get, old_url)).not_to have_been_made
  end

  it 'does not treat an unusable inline affiliations value as success' do
    fetch_actor(canCreate: 'admin', affiliations: { 'type' => 'Note', 'content' => 'nope' })

    result = nil
    Sidekiq::Testing.fake! do
      result = service.call(account)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker.jobs).to be_empty
    end

    account.reload
    expect(result).to have_attributes(state: 'partial', actor: 'refreshed', affiliations: 'failed')
    expect(account.group_affiliations.pluck(:relationship)).to eq ['member']
    expect(account.affiliations_fetched_at).to eq Time.utc(2026, 1, 1)
  end

  it 'does not refresh affiliations after the lease check fails' do
    fetch_actor(canCreate: 'admin', affiliations: old_url)
    expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)

    expect(service.call(account, on_step: -> { false })).to be_nil

    account.reload
    expect(account.can_create_affiliation).to eq 'admin'
    expect(account.group_affiliations.pluck(:relationship)).to eq ['member']
    expect(account.affiliations_fetched_at).to eq Time.utc(2026, 1, 1)
  end

  it 'does not fetch affiliations when the actor is no longer a group' do
    fetch_actor(type: 'Person', canCreate: 'admin', affiliations: old_url)
    expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)

    result = service.call(account)

    account.reload
    expect(result).to have_attributes(state: 'completed', actor: 'skipped', affiliations: 'skipped')
    expect(account.actor_type).to eq 'Person'
    expect(account.can_create_affiliation).to be_nil
    expect(account.permission_definitions_fetched_at).to be_nil
  end

  def fetch_actor(type: 'Group', canCreate: nil, canView: nil, affiliations: nil)
    payload = {
      id: uri,
      type: type,
      inbox: 'https://mitra.example/users/group/inbox',
    }
    payload[:canCreate] = canCreate unless canCreate.nil?
    payload[:canView] = canView unless canView.nil?
    payload[:affiliations] = affiliations unless affiliations.nil?
    fetcher = instance_double(ActivityPub::FetchRemoteAccountService)
    processor = nil
    allow(ActivityPub::FetchRemoteAccountService).to receive(:new).and_return(fetcher)
    allow(fetcher).to receive(:call) do |requested_uri, **options|
      expect(requested_uri).to eq account.uri
      expect(options[:only_key]).to eq false
      expect(options[:defer_group_affiliations]).to eq true
      processor = ActivityPub::ProcessAccountService.new
      processor.call(account.username, account.domain, payload.with_indifferent_access, defer_group_affiliations: true)
    end
    allow(fetcher).to receive(:deferred_group_affiliations_collection) { processor&.deferred_group_affiliations_collection }
    allow(fetcher).to receive(:deferred_group_affiliations_invalid) { processor&.deferred_group_affiliations_invalid }
  end

  def relationship_collection(subject, relationship)
    {
      '@context' => 'https://www.w3.org/ns/activitystreams',
      'type' => 'OrderedCollection',
      'orderedItems' => [
        {
          'type' => 'Relationship',
          'subject' => subject,
          'relationship' => relationship,
          'object' => uri,
        },
      ],
    }
  end

  def stub_collection(url, body)
    stub_request(:get, url).to_return(
      status: 200,
      body: Oj.dump(body),
      headers: { 'Content-Type' => 'application/activity+json' }
    )
  end
end
