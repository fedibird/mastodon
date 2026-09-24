# frozen_string_literal: true

require 'rails_helper'

describe ActivityPub::NoteSerializer do
  let!(:account) { Fabricate(:account) }
  let!(:other)   { Fabricate(:account) }
  let!(:parent)  { Fabricate(:status, account: account, visibility: :public) }
  let!(:reply1)  { Fabricate(:status, account: account, thread: parent, visibility: :public) }
  let!(:reply2)  { Fabricate(:status, account: account, thread: parent, visibility: :public) }
  let!(:reply3)  { Fabricate(:status, account: other, thread: parent, visibility: :public) }
  let!(:reply4)  { Fabricate(:status, account: account, thread: parent, visibility: :public) }
  let!(:reply5)  { Fabricate(:status, account: account, thread: parent, visibility: :direct) }

  before(:each) do
    @serialization = ActiveModelSerializers::SerializableResource.new(parent, serializer: ActivityPub::NoteSerializer, adapter: ActivityPub::Adapter)
  end

  subject { JSON.parse(@serialization.to_json) }

  it 'has a Note type' do
    expect(subject['type']).to eql('Note')
  end

  it 'has a replies collection' do
    expect(subject['replies']['type']).to eql('Collection')
  end

  it 'has a replies collection with a first Page' do
    expect(subject['replies']['first']['type']).to eql('CollectionPage')
  end

  it 'includes public self-replies in its replies collection' do
    expect(subject['replies']['first']['items']).to include(reply1.uri, reply2.uri, reply4.uri)
  end

  it 'does not include replies from others in its replies collection' do
    expect(subject['replies']['first']['items']).to_not include(reply3.uri)
  end

  it 'does not include replies with direct visibility in its replies collection' do
    expect(subject['replies']['first']['items']).to_not include(reply5.uri)
  end

  it 'omits updated until the status has been edited' do
    expect(subject).not_to have_key('updated')
  end

  it 'serializes sensitive without requiring media' do
    parent.update!(sensitive: true)
    json = JSON.parse(ActiveModelSerializers::SerializableResource.new(parent, serializer: ActivityPub::NoteSerializer, adapter: ActivityPub::Adapter).to_json)

    expect(json['sensitive']).to be true
  end

  it 'serializes sensitive with media' do
    Fabricate(:media_attachment, account: account, status: parent)
    parent.update!(sensitive: true)
    json = JSON.parse(ActiveModelSerializers::SerializableResource.new(parent.reload, serializer: ActivityPub::NoteSerializer, adapter: ActivityPub::Adapter).to_json)

    expect(json['sensitive']).to be true
  end

  it 'serializes a normal status as not sensitive' do
    expect(subject['sensitive']).to be false
  end

  it 'serializes a sensitized account as sensitive' do
    account.sensitize!
    json = JSON.parse(ActiveModelSerializers::SerializableResource.new(parent.reload, serializer: ActivityPub::NoteSerializer, adapter: ActivityPub::Adapter).to_json)

    expect(json['sensitive']).to be true
  end

  it 'serializes updated from edited_at' do
    parent.update!(edited_at: Time.utc(2026, 9, 22, 3, 4, 5))
    serialization = ActiveModelSerializers::SerializableResource.new(parent, serializer: ActivityPub::NoteSerializer, adapter: ActivityPub::Adapter)
    json = JSON.parse(serialization.to_json)

    expect(json['updated']).to eq parent.edited_at.iso8601
  end
end
