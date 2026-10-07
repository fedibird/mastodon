require 'rails_helper'

RSpec.describe AccountMergingWorker do
  let(:actor_uri) { 'https://example.com/groups/group' }
  let(:fetched_at) { Time.utc(2026, 2, 1) }
  let(:canonical) do
    Fabricate(
      :account,
      username: 'group',
      domain: 'example.com',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: actor_uri
    )
  end
  let(:duplicate) do
    Fabricate(
      :account,
      username: 'groupdup',
      domain: 'example.com',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: actor_uri
    )
  end

  it 'discards a stale duplicate snapshot instead of mixing it into the fresh one' do
    canonical.update_columns(
      affiliations_url: 'https://example.com/groups/group/affiliations',
      affiliations_fetched_at: fetched_at
    )
    duplicate.update_columns(
      affiliations_url: 'https://example.com/groups/group/old',
      affiliations_fetched_at: Time.utc(2026, 1, 1)
    )
    GroupAffiliation.create!(group_account: canonical, subject_uri: 'https://remote.example/users/bob', relationship: 'admin')
    GroupAffiliation.create!(group_account: duplicate, subject_uri: 'https://remote.example/users/alice', relationship: 'admin')

    described_class.new.perform(canonical.id)

    expect(Account.where(id: duplicate.id)).to be_empty
    expect(canonical.group_affiliations.pluck(:subject_uri, :relationship)).to eq [['https://remote.example/users/bob', 'admin']]
    expect(GroupAffiliation.where(subject_uri: 'https://remote.example/users/alice')).to be_empty
    expect(canonical.reload.affiliations_url).to eq 'https://example.com/groups/group/affiliations'
    expect(canonical.affiliations_fetched_at).to eq fetched_at
  end

  it 'preserves an authoritative empty snapshot when the duplicate still has rows' do
    canonical.update_columns(affiliations_url: nil, affiliations_fetched_at: fetched_at)
    duplicate.update_columns(
      affiliations_url: 'https://example.com/groups/group/old',
      affiliations_fetched_at: Time.utc(2026, 1, 1)
    )
    GroupAffiliation.create!(group_account: duplicate, subject_uri: 'https://remote.example/users/alice', relationship: 'admin')

    described_class.new.perform(canonical.id)

    expect(Account.where(id: duplicate.id)).to be_empty
    expect(canonical.group_affiliations).to be_empty
    expect(GroupAffiliation.where(group_account_id: canonical.id)).to be_empty
    expect(canonical.reload.affiliations_url).to be_nil
    expect(canonical.affiliations_fetched_at).to eq fetched_at
  end
end
