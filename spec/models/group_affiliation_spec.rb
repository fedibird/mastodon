require 'rails_helper'

RSpec.describe GroupAffiliation do
  let(:group) { Fabricate(:account, username: 'group', domain: 'example.com', actor_type: 'Group', uri: 'https://example.com/groups/group') }

  it 'requires a subject and a relationship within the index limits' do
    record = described_class.new(group_account: group, relationship: 'admin')

    expect(record).not_to be_valid
    record.subject_uri = 'https://remote.example/users/alice'
    expect(record).to be_valid

    record.subject_uri = 'https://remote.example/users/' + ('a' * described_class::SUBJECT_URI_MAX_LENGTH)
    expect(record).not_to be_valid
  end

  it 'reassigns cached affiliations onto the kept account during a merge' do
    duplicate = Fabricate(:account, username: 'group2', domain: 'example.com', actor_type: 'Group', uri: 'https://example.com/groups/group')
    described_class.create!(group_account: group, subject_uri: 'https://remote.example/users/alice', relationship: 'admin')
    described_class.create!(group_account: duplicate, subject_uri: 'https://remote.example/users/alice', relationship: 'admin')
    described_class.create!(group_account: duplicate, subject_uri: 'https://remote.example/users/bob', relationship: 'trusted-poster')

    group.merge_with!(duplicate)

    expect(group.group_affiliations.pluck(:subject_uri, :relationship)).to contain_exactly(
      ['https://remote.example/users/alice', 'admin'],
      ['https://remote.example/users/bob', 'trusted-poster']
    )
  end

  it 'removes affiliations when the group account is deleted' do
    record = described_class.create!(group_account: group, subject_uri: 'https://remote.example/users/alice', relationship: 'admin')

    group.destroy!

    expect(described_class.where(id: record.id)).to be_empty
  end
end
