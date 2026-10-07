# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'ActivityPub audience addressing' do
  let(:group) do
    Fabricate(
      :account,
      username: 'group',
      domain: 'group.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://group.example/users/group',
      inbox_url: 'https://group.example/users/group/inbox',
      followers_url: 'https://group.example/users/group/followers'
    )
  end
  let(:status) { Fabricate(:status, visibility: :public, text: 'Hello', audience_account: group) }

  def serialize(model, serializer)
    JSON.parse(ActiveModelSerializers::SerializableResource.new(model, serializer: serializer, adapter: ActivityPub::Adapter).to_json)
  end

  it 'puts the group actor on the Create activity and the Note audience' do
    json = serialize(ActivityPub::ActivityPresenter.from_status(status), ActivityPub::ActivitySerializer)

    expect(json['type']).to eq 'Create'
    expect(json['to']).to include('https://www.w3.org/ns/activitystreams#Public', group.uri)
    expect(json['object']['type']).to eq 'Note'
    expect(json['object']['audience']).to eq group.uri
    expect(json['object']['to']).to include('https://www.w3.org/ns/activitystreams#Public', group.uri)
    expect(json['to']).not_to include(group.followers_url)
  end

  it 'adds the group actor to Delete addressing' do
    json = serialize(status, ActivityPub::DeleteSerializer)

    expect(json['type']).to eq 'Delete'
    expect(json['to']).to include('https://www.w3.org/ns/activitystreams#Public', group.uri)
  end

  it 'leaves Delete addressing public when there is no audience target' do
    plain = Fabricate(:status, visibility: :public)
    json = serialize(plain, ActivityPub::DeleteSerializer)

    expect(json['to']).to eq ['https://www.w3.org/ns/activitystreams#Public']
    expect(json).not_to have_key('audience')
  end
end
