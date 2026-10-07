# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingContext::GroupPermissionDefinitionResolver do
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
  let(:service) { described_class.new }

  it 'returns a fresh canCreate identifier without reading the network' do
    group.update_columns(
      can_create_affiliation: 'trusted-poster',
      can_view_affiliation: 'member',
      permission_definitions_fetched_at: 23.hours.ago
    )

    expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)

    result = service.call(group)

    expect(result).to include(
      snapshot_status: 'fresh',
      can_create: 'trusted-poster',
      can_view: 'member'
    )
    expect(result[:fetched_at]).to eq group.reload.permission_definitions_fetched_at.utc.iso8601
  end

  it 'hides a stale definition' do
    group.update_columns(
      can_create_affiliation: 'admin',
      permission_definitions_fetched_at: 2.days.ago
    )

    expect(service.call(group)).to include(
      snapshot_status: 'stale',
      can_create: nil,
      can_view: nil
    )
  end

  it 'reports unfetched when the actor document has not been read for these properties' do
    group.update_columns(can_create_affiliation: 'admin', permission_definitions_fetched_at: nil)

    expect(service.call(group)).to include(
      snapshot_status: 'unfetched',
      fetched_at: nil,
      can_create: nil,
      can_view: nil
    )
  end

  it 'keeps a fresh snapshot with no published threshold distinct from unfetched' do
    group.update_columns(
      can_create_affiliation: nil,
      can_view_affiliation: nil,
      permission_definitions_fetched_at: Time.now.utc
    )

    expect(service.call(group)).to include(
      snapshot_status: 'fresh',
      can_create: nil,
      can_view: nil
    )
  end

  it 'returns unavailable for an account that is not a group' do
    person = Fabricate(:account, username: 'alice')

    expect(service.call(person)[:snapshot_status]).to eq 'unavailable'
  end
end
