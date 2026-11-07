# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Local Group Actor protocol advertisement cache boundary' do
  let(:group) { Fabricate(:account, username: 'routeprotocolgroup', actor_type: 'Group') }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(ActivityPub::GroupProtocolAdvertisement::EMIT_ENV).and_return('false')
    allow(ENV).to receive(:[]).with(ActivityPub::GroupProtocolAdvertisement::ACTOR_IDS_ENV).and_return(group.id.to_s)
  end

  def get_actor
    get "/users/#{group.username}", headers: { 'Accept' => 'application/activity+json' }
    expect(response).to have_http_status(200)
    body_as_json
  end

  it 'does not reuse the advertised JSON after the gate is disabled' do
    advertisement = ActivityPub::GroupProtocolAdvertisement

    off = get_actor
    expect(off).not_to have_key(:fedibirdGroupProtocols)

    allow(ENV).to receive(:[]).with(advertisement::EMIT_ENV).and_return('true')
    on = get_actor
    expect(on[:fedibirdGroupProtocols]).to eq([advertisement::MENTION_FOLLOW_ANNOUNCE_IRI])
    expect(on[:type]).to eq('Group')

    allow(ENV).to receive(:[]).with(advertisement::EMIT_ENV).and_return('false')
    disabled_again = get_actor
    expect(disabled_again).not_to have_key(:fedibirdGroupProtocols)
    expect(disabled_again[:id]).to eq(off[:id])
    expect(disabled_again[:publicKey]).to eq(off[:publicKey])
  end
end
