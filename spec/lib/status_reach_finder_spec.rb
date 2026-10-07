# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StatusReachFinder do
  let(:group) do
    Fabricate(
      :account,
      username: 'group',
      domain: 'group.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://group.example/users/group',
      inbox_url: 'https://group.example/users/group/inbox',
      shared_inbox_url: 'https://group.example/inbox',
      followers_url: 'https://group.example/users/group/followers'
    )
  end
  let(:status) { Fabricate(:status, visibility: :public, audience_account: group) }

  it 'includes the group actor inbox in update reach' do
    expect(described_class.new(status).inboxes).to include(group.inbox_url)
    expect(described_class.new(status).inboxes).not_to include(group.shared_inbox_url, group.followers_url)
  end

  it 'includes the group actor inbox in delete reach' do
    inboxes = described_class.new(status, unsafe: true).inboxes

    expect(inboxes).to include(group.inbox_url)
    expect(inboxes.count(group.inbox_url)).to eq 1
    expect(inboxes).not_to include(group.shared_inbox_url, group.followers_url)
  end

  it 'keeps one copy when the group actor inbox is already in reach' do
    follower = Fabricate(:account, protocol: :activitypub, inbox_url: group.inbox_url, shared_inbox_url: '', domain: 'follower.example')
    follower.follow!(status.account)

    inboxes = described_class.new(status).inboxes

    expect(inboxes.count(group.inbox_url)).to eq 1
  end
end
