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

  it 'does not merge a duplicate affiliation snapshot into the canonical account' do
    fetched_at = Time.utc(2026, 2, 1)
    duplicate = Fabricate(:account, username: 'group2', domain: 'example.com', actor_type: 'Group', uri: 'https://example.com/groups/group')
    group.update_columns(affiliations_url: 'https://example.com/groups/group/affiliations', affiliations_fetched_at: fetched_at)
    duplicate.update_columns(affiliations_url: 'https://example.com/groups/group/old', affiliations_fetched_at: Time.utc(2026, 1, 1))
    described_class.create!(group_account: group, subject_uri: 'https://remote.example/users/bob', relationship: 'admin')
    described_class.create!(group_account: duplicate, subject_uri: 'https://remote.example/users/alice', relationship: 'admin')

    group.merge_with!(duplicate)

    expect(group.group_affiliations.pluck(:subject_uri, :relationship)).to eq [['https://remote.example/users/bob', 'admin']]
    expect(duplicate.group_affiliations.pluck(:subject_uri)).to eq ['https://remote.example/users/alice']
    expect(group.reload.affiliations_url).to eq 'https://example.com/groups/group/affiliations'
    expect(group.affiliations_fetched_at).to eq fetched_at
  end

  it 'removes affiliations when the group account is deleted' do
    record = described_class.create!(group_account: group, subject_uri: 'https://remote.example/users/alice', relationship: 'admin')

    group.destroy!

    expect(described_class.where(id: record.id)).to be_empty
  end
end
