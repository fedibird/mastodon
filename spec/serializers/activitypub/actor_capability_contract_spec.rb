# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'ActivityPub Actor capability-discovery contract (P3-A)' do
  def actor_json(account)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        account,
        serializer: ActivityPub::ActorSerializer,
        adapter: ActivityPub::Adapter
      ).to_json
    )
  end

  it 'keeps a local Group actor distinct from any new posting protocol claim' do
    group = Fabricate(:account, username: 'contractgroup', actor_type: 'Group')

    json = actor_json(group)

    expect(json['type']).to eq('Group')
    expect(json['id']).to eq(ActivityPub::TagManager.instance.uri_for(group))
    expect(json['publicKey']).to be_present
    expect(json).not_to have_key('fedibirdGroupProtocols')
    expect(json).not_to have_key('groupProtocols')
    expect(json).not_to have_key('canPost')
    expect(json).not_to have_key('viewerCapabilities')
    expect(json).not_to have_key('affiliations')
    expect(json).not_to have_key('roles')
  end

  it 'does not imply a Group protocol for an ordinary Person' do
    person = Fabricate(:account, username: 'contractperson')

    json = actor_json(person)

    expect(json['type']).to eq('Person')
    expect(json).not_to have_key('fedibirdGroupProtocols')
    expect(json).not_to have_key('canPost')
    expect(json).not_to have_key('viewerCapabilities')
  end
end
