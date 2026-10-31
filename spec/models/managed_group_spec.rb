# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ManagedGroup do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  let(:requester) { Fabricate(:user) }
  let(:request) do
    GroupCreationRequest.create!(
      requester_account: requester.account,
      username: 'managedgroup',
      display_name: 'Managed',
      note: 'Notes'
    )
  end

  it 'does not enroll an existing local group on its own' do
    legacy = Fabricate(:account, username: 'legacygroup', actor_type: 'Group')

    expect(described_class.find_by(account_id: legacy.id)).to be_nil
    expect(GroupRoleAssignment.where(group_account_id: legacy.id)).to be_empty

    record = described_class.new(account: legacy, origin: :legacy_unassigned)
    expect(record).not_to be_valid
    expect(record.errors.added?(:origin, :invalid)).to be true
    expect(described_class.count).to eq 0
  end

  it 'attaches one approved-request row to the matching new group account' do
    group = Fabricate(:account, username: request.username, actor_type: 'Group')
    managed = described_class.create!(account: group, origin: :approved_request, creation_request: request)

    expect(managed.account).to eq group
    expect(group.reload.managed_group).to eq managed

    other = Fabricate(:account, username: 'othergroup', actor_type: 'Group')
    mismatched = described_class.new(account: other, origin: :approved_request, creation_request: request)
    expect(mismatched).not_to be_valid

    person = Fabricate(:account, username: 'notagroup')
    expect(described_class.new(account: person, origin: :approved_request, creation_request: request)).not_to be_valid

    remote = Fabricate(:account, username: request.username, domain: 'groups.example', actor_type: 'Group', uri: 'https://groups.example/groups/managedgroup')
    expect(described_class.new(account: remote, origin: :approved_request, creation_request: request)).not_to be_valid
  end
end
