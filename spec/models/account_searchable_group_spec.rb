# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Account, 'user-less managed groups' do
  let(:person) { Fabricate(:user) }

  it 'includes an approved user-less group in searchable and discoverable scopes' do
    request = GroupCreationRequest.create!(
      requester_account: person.account,
      username: 'findme',
      display_name: 'Find Me',
      note: 'visible'
    )
    group = Fabricate(:account, username: 'findme', actor_type: 'Group', discoverable: true)
    group.account_stat.save!
    ManagedGroup.create!(account: group, origin: :approved_request, creation_request: request)
    unapproved = Fabricate(:user, confirmed_at: Time.current)
    unapproved.update_columns(approved: false)
    legacy = Fabricate(:user, account: Fabricate(:account, username: 'legacyvisible', actor_type: 'Group', discoverable: true))
    orphan = Fabricate(:account, username: 'orphanlocal', actor_type: 'Group', discoverable: true)
    remote = Fabricate(:account, username: 'remotegroup', domain: 'groups.example', actor_type: 'Group', discoverable: true)
    legacy.account.account_stat.save!
    orphan.account_stat.save!
    remote.account_stat.save!

    searchable_ids = described_class.searchable.pluck(:id)
    expect(searchable_ids).to include(group.id, legacy.account.id, remote.id)
    expect(searchable_ids).not_to include(unapproved.account.id, orphan.id)

    directory_ids = described_class.discoverable.groups.pluck(:id)
    expect(directory_ids).to include(group.id, legacy.account.id, remote.id)
    expect(directory_ids).not_to include(unapproved.account.id, orphan.id)
  end
end
