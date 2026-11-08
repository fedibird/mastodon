# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityPub::NoteSerializer do
  let!(:account) { Fabricate(:account) }
  let!(:parent) { Fabricate(:status, account: account, visibility: :public) }

  subject do
    JSON.parse(ActiveModelSerializers::SerializableResource.new(parent, serializer: described_class, adapter: ActivityPub::Adapter).to_json)
  end

  it 'serializes sensitive without requiring media' do
    parent.update!(sensitive: true)
    json = JSON.parse(ActiveModelSerializers::SerializableResource.new(parent, serializer: ActivityPub::NoteSerializer, adapter: ActivityPub::Adapter).to_json)

    expect(json['sensitive']).to be true
  end

  it 'serializes sensitive with media' do
    # This checks Note serialization, not local thumbnail generation.
    attach_remote_test_image(parent)
    parent.update!(sensitive: true)
    json = JSON.parse(ActiveModelSerializers::SerializableResource.new(parent.reload, serializer: ActivityPub::NoteSerializer, adapter: ActivityPub::Adapter).to_json)

    expect(json['attachment']).to be_present
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
end
