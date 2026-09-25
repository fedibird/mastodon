# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'OAuth access token usage tracking' do
  let(:user) { Fabricate(:user) }
  let!(:account) { Fabricate(:account, username: 'alice') }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read') }

  def lookup(ip, authenticated: true)
    headers = authenticated ? { 'Authorization' => "Bearer #{token.token}" } : {}
    get '/api/v1/accounts/lookup', params: { acct: 'alice' }, headers: headers, env: { 'REMOTE_ADDR' => ip }
  end

  it 'records last use on the first authenticated request' do
    lookup('203.0.113.10')

    expect(response).to have_http_status(200)
    token.reload
    expect(token.last_used_at).to be_within(5.seconds).of(Time.now.utc)
    expect(token.last_used_ip).to eq(IPAddr.new('203.0.113.10'))
  end

  it 'does not refresh usage again until 24 hours have passed' do
    t0 = Time.utc(2026, 9, 25, 12, 0, 0)

    travel_to(t0) { lookup('203.0.113.10') }
    token.reload
    recorded_at = token.last_used_at

    travel_to(t0 + 23.hours) { lookup('198.51.100.20') }
    token.reload
    expect(token.last_used_at).to eq(recorded_at)
    expect(token.last_used_ip).to eq(IPAddr.new('203.0.113.10'))

    travel_to(t0 + 24.hours + 1.second) { lookup('198.51.100.30') }
    token.reload
    expect(token.last_used_at).to be > recorded_at
    expect(token.last_used_ip).to eq(IPAddr.new('198.51.100.30'))
  end

  it 'leaves tokens untouched for an anonymous request' do
    lookup('203.0.113.10', authenticated: false)

    expect(response).to have_http_status(200)
    expect(token.reload.last_used_at).to be_nil
    expect(token.last_used_ip).to be_nil
  end
end
