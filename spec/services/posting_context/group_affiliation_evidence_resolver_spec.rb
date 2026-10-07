require 'rails_helper'

RSpec.describe PostingContext::GroupAffiliationEvidenceResolver do
  let(:group) do
    Fabricate(
      :account,
      username: 'group',
      domain: 'group.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://group.example/groups/group'
    )
  end
  let(:viewer) { Fabricate(:account, username: 'alice') }
  let(:viewer_uri) { ActivityPub::TagManager.instance.uri_for(viewer) }
  let(:service) { described_class.new }

  it 'returns fresh positive relationships for the viewer actor URI only' do
    group.update_columns(affiliations_fetched_at: Time.now.utc)
    GroupAffiliation.create!(group_account: group, subject_uri: viewer_uri, relationship: 'trusted-poster', affiliation_uri: 'https://group.example/relationships/2')
    GroupAffiliation.create!(group_account: group, subject_uri: viewer_uri, relationship: 'admin', affiliation_uri: 'https://group.example/relationships/1')
    GroupAffiliation.create!(group_account: group, subject_uri: 'https://other.example/users/bob', relationship: 'admin', affiliation_uri: 'https://group.example/relationships/bob')
    GroupAffiliation.create!(group_account: group, subject_uri: viewer.acct, relationship: 'moderator')

    expect(ActivityPub::TagManager.instance).to receive(:uri_for).with(viewer).and_call_original

    result = service.call(group, viewer)

    expect(result).to include(
      source: 'fep-5219-affiliations',
      snapshot_status: 'fresh'
    )
    expect(result[:fetched_at]).to eq group.reload.affiliations_fetched_at.utc.iso8601
    expect(result[:relationships]).to eq [
      { relationship: 'admin', affiliation_uri: 'https://group.example/relationships/1' },
      { relationship: 'trusted-poster', affiliation_uri: 'https://group.example/relationships/2' },
    ]
    expect(result[:relationships].map { |row| row[:relationship] }).not_to include('moderator')
    expect(result.to_s).not_to include('bob')
  end

  it 'returns custom relationship labels without interpreting them' do
    group.update_columns(affiliations_fetched_at: 23.hours.ago)
    GroupAffiliation.create!(group_account: group, subject_uri: viewer_uri, relationship: 'https://vocab.example/roles/foo', affiliation_uri: nil)
    GroupAffiliation.create!(group_account: group, subject_uri: viewer_uri, relationship: 'Admin', affiliation_uri: 'https://group.example/relationships/admin')
    GroupAffiliation.create!(group_account: group, subject_uri: viewer_uri, relationship: 'trusted-poster', affiliation_uri: nil)

    result = service.call(group, viewer)

    expect(result[:snapshot_status]).to eq 'fresh'
    expect(result[:relationships]).to eq [
      { relationship: 'Admin', affiliation_uri: 'https://group.example/relationships/admin' },
      { relationship: 'https://vocab.example/roles/foo', affiliation_uri: nil },
      { relationship: 'trusted-poster', affiliation_uri: nil },
    ]
  end

  it 'hides stale relationships' do
    group.update_columns(affiliations_fetched_at: 2.days.ago)
    GroupAffiliation.create!(group_account: group, subject_uri: viewer_uri, relationship: 'admin', affiliation_uri: 'https://group.example/relationships/1')

    result = service.call(group, viewer)

    expect(result[:snapshot_status]).to eq 'stale'
    expect(result[:relationships]).to eq []
    expect(result[:fetched_at]).to eq group.reload.affiliations_fetched_at.utc.iso8601
  end

  it 'treats an advertised collection without a snapshot as unfetched' do
    group.update_columns(affiliations_url: 'https://group.example/groups/group/affiliations', affiliations_fetched_at: nil)

    result = service.call(group, viewer)

    expect(result).to include(
      snapshot_status: 'unfetched',
      fetched_at: nil,
      relationships: []
    )
  end

  it 'treats a group with no collection reference as unavailable' do
    result = service.call(group, viewer)

    expect(result).to include(
      snapshot_status: 'unavailable',
      fetched_at: nil,
      relationships: []
    )
  end

  it 'keeps a fresh authoritative empty snapshot distinct from unavailable' do
    group.update_columns(affiliations_url: nil, affiliations_fetched_at: Time.now.utc)

    result = service.call(group, viewer)

    expect(result[:snapshot_status]).to eq 'fresh'
    expect(result[:relationships]).to eq []
    expect(result[:fetched_at]).to be_present
  end

  it 'treats a day-old boundary loosely around the freshness window' do
    group.update_columns(affiliations_fetched_at: 25.hours.ago)
    GroupAffiliation.create!(group_account: group, subject_uri: viewer_uri, relationship: 'admin')

    expect(service.call(group, viewer)[:snapshot_status]).to eq 'stale'
  end

  it 'returns unavailable without a viewer' do
    group.update_columns(affiliations_fetched_at: Time.now.utc)

    expect(service.call(group, nil)).to include(
      snapshot_status: 'unavailable',
      relationships: []
    )
  end
end
