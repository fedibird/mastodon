# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GroupProtocol public Actor discovery boundary (P3-A)' do
  it 'provides only viewer-independent metadata for a local Group' do
    group = Fabricate(:account, username: 'publicgroup', actor_type: 'Group')

    data = GroupProtocol.public_metadata(group)

    expect(data.keys).to match_array(GroupProtocol::PUBLIC_KEYS)
    expect(data[:profile][:kind]).to eq('fedibird_mention_follow_announce')
    expect(data[:profile][:delivery]).to eq('announce_original_uri')
    expect(data[:authorizes_posting]).to be(false)
    expect(data).not_to have_key(:viewer_capabilities)
    expect(data).not_to have_key(:can_post)
  end

  it 'does not convert a remote Group into a posting grant' do
    group = Fabricate(
      :account,
      username: 'remotegroup',
      domain: 'group.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://group.example/users/remotegroup',
      inbox_url: 'https://group.example/inbox'
    )

    data = GroupProtocol.public_metadata(group)

    expect(data[:profile][:kind]).to eq('unknown')
    expect(data[:fedibird_posting]).to eq('withheld')
    expect(data[:authorizes_posting]).to be(false)
    expect(data).not_to have_key(:viewer_capabilities)
  end
end
