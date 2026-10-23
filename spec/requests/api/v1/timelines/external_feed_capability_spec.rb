# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Timelines::ExternalFeedCapabilities' do
  let(:user) { Fabricate(:user) }

  after do
    Setting.external_bridge_feeds = false
    Setting.external_bridge_feeds_testers = ''
  end

  it 'reports the signed-in user and not another user of the same account' do
    get '/api/v1/timelines/external_feed_capability', headers: auth_headers_for(user)

    expect(response).to have_http_status(200)
    expect(JSON.parse(response.body)).to eq('permitted' => false)

    other = share_account_user(user.account)
    enable_external_bridge_feeds!(other)
    get '/api/v1/timelines/external_feed_capability', headers: auth_headers_for(user)

    expect(JSON.parse(response.body)).to eq('permitted' => false)

    enable_external_bridge_feeds!(user)
    get '/api/v1/timelines/external_feed_capability', headers: auth_headers_for(user)

    expect(JSON.parse(response.body)).to eq('permitted' => true)
  end
end
