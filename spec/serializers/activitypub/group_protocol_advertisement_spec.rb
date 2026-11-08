# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityPub::ActorSerializer do
  let(:group) { Fabricate(:account, username: 'actorprotocolgroup', actor_type: 'Group') }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(ActivityPub::GroupProtocolAdvertisement::EMIT_ENV).and_return('true')
    allow(ENV).to receive(:[]).with(ActivityPub::GroupProtocolAdvertisement::ACTOR_IDS_ENV).and_return(group.id.to_s)
  end

  def actor_json(account)
    JSON.parse(ActiveModelSerializers::SerializableResource.new(account, serializer: described_class, adapter: ActivityPub::Adapter).to_json)
  end

  it 'adds only a local Group protocol IRI and its matching JSON-LD context' do
    advertisement = ActivityPub::GroupProtocolAdvertisement
    json = actor_json(group)

    expect(json['type']).to eq('Group')
    expect(json['fedibirdGroupProtocols']).to eq([advertisement::MENTION_FOLLOW_ANNOUNCE_IRI])
    expect(json.fetch('@context').last.fetch('fedibirdGroupProtocols')).to eq(
      '@id' => advertisement::PROPERTY_IRI,
      '@type' => '@id',
      '@container' => '@set'
    )
    expect(json).not_to have_key('groupProtocols')
    expect(json).not_to have_key('canPost')
    expect(json).not_to have_key('viewerCapabilities')
  end

  it 'preserves existing actor output, including context, when disabled' do
    flag = ActivityPub::GroupProtocolAdvertisement::EMIT_ENV
    allow(ENV).to receive(:[]).with(flag).and_return('false')
    baseline = actor_json(group)

    allow(ENV).to receive(:[]).with(flag).and_return('true')
    advertised = actor_json(group)

    expect(baseline).not_to have_key('fedibirdGroupProtocols')
    expect(baseline.fetch('@context').last).not_to have_key('fedibirdGroupProtocols')
    expect(advertised.except('@context', 'fedibirdGroupProtocols')).to eq(baseline.except('@context'))
  end

  it 'does not add Group claims for a Person or a suspended Group' do
    person = Fabricate(:account, username: 'actorprotocolperson')
    expect(actor_json(person)).not_to have_key('fedibirdGroupProtocols')

    group.update_columns(suspended_at: Time.current)
    suspended = actor_json(group)
    expect(suspended).not_to have_key('fedibirdGroupProtocols')
    expect(suspended.fetch('@context').last).not_to have_key('fedibirdGroupProtocols')
  end
end
