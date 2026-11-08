# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'ActivityPub Note capability-discovery contract (P3-A)' do
  def note_json(status)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        status,
        serializer: ActivityPub::NoteSerializer,
        adapter: ActivityPub::Adapter
      ).to_json
    )
  end

  it 'keeps a Note audience distinct from FEP group delivery support' do
    group = Fabricate(:account, username: 'audiencegroup', actor_type: 'Group')
    status = Fabricate(:status, visibility: :public, audience_account: group)

    json = note_json(status)

    expect(json['type']).to eq('Note')
    expect(json['audience']).to eq(ActivityPub::TagManager.instance.uri_for(group))
    expect(json).not_to have_key('fedibirdGroupProtocols')
    expect(json).not_to have_key('groupProtocols')
    expect(json).not_to have_key('canPost')
  end

  it 'keeps existing references separate from quote/FEP consent claims' do
    status = Fabricate(:status, visibility: :public)

    json = note_json(status)

    expect(json.dig('references', 'type')).to eq('Collection')
    expect(json).not_to have_key('quoteUri')
    expect(json).not_to have_key('quoteAuthorization')
    expect(json).not_to have_key('canQuote')
  end
end
