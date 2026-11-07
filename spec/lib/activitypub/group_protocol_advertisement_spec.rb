# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityPub::GroupProtocolAdvertisement do
  let(:group) { Fabricate(:account, username: 'protocolgrouptest', actor_type: 'Group') }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(described_class::EMIT_ENV).and_return('true')
    allow(ENV).to receive(:[]).with(described_class::ACTOR_IDS_ENV).and_return(group.id.to_s)
  end

  it 'advertises only an explicitly allowlisted local Group with the server profile' do
    expect(GroupProtocol).not_to receive(:assess)
    expect(Node).not_to receive(:resolve_domain)

    expect(described_class.advertised?(group)).to be(true)
    expect(described_class.protocol_iris).to eq([described_class::MENTION_FOLLOW_ANNOUNCE_IRI])
    expect(described_class.cache_key_for(group)).to include('fedibird-group-protocols-v1')
  end

  it 'fails closed when the flag or allowlist is missing or malformed' do
    allow(ENV).to receive(:[]).with(described_class::EMIT_ENV).and_return('TRUE')
    expect(described_class.advertised?(group)).to be(false)

    allow(ENV).to receive(:[]).with(described_class::EMIT_ENV).and_return('true')
    allow(ENV).to receive(:[]).with(described_class::ACTOR_IDS_ENV).and_return('')
    expect(described_class.advertised?(group)).to be(false)

    allow(ENV).to receive(:[]).with(described_class::ACTOR_IDS_ENV).and_return('bogus,0,-1')
    expect(described_class.advertised?(group)).to be(false)
    expect(described_class.cache_key_for(group)).to be_nil
  end

  it 'rejects remote, suspended, and non-Group actors even when listed' do
    remote = Fabricate(:account, username: 'remotegroup', domain: 'group.example', actor_type: 'Group', protocol: :activitypub, uri: 'https://group.example/users/remotegroup', inbox_url: 'https://group.example/inbox')
    person = Fabricate(:account, username: 'ordinaryperson')

    allow(ENV).to receive(:[]).with(described_class::ACTOR_IDS_ENV).and_return([group.id, remote.id, person.id].join(','))

    expect(described_class.advertised?(remote)).to be(false)
    expect(described_class.advertised?(person)).to be(false)

    group.update_columns(suspended_at: Time.current)
    expect(described_class.advertised?(group)).to be(false)
  end
end
