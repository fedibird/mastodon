# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'User-less group actor' do
  before do
    load Rails.root.join('db', 'seeds', '03_roles.rb')
    Setting.group_creation_requests = true
    stub_webpacker_manifest
  end

  after { Setting.group_creation_requests = false }

  let(:reviewer) { user_with_role('Owner') }
  let(:requester) { Fabricate(:user, account: Fabricate(:account, username: 'grouprequester')) }
  let(:group) do
    request = GroupCreationRequest.create!(
      requester_account: requester.account,
      username: 'openedgroup',
      display_name: 'Opened Group',
      note: 'A public group'
    )
    GroupCreationRequests::ApproveService.call(request: request, reviewer_account: reviewer.account).group_account
  end

  it 'serves WebFinger, ActivityPub actor JSON, REST, and the group timeline' do
    status = Fabricate(:status, account: group, text: 'group hello', visibility: :public)

    get '/.well-known/webfinger', params: { resource: group.to_webfinger_s }
    expect(response).to have_http_status(200)
    expect(body_as_json[:subject]).to eq group.to_webfinger_s

    get "/users/#{group.username}", headers: { 'Accept' => 'application/activity+json' }
    expect(response).to have_http_status(200)
    body = body_as_json
    expect(body[:type]).to eq 'Group'
    expect(body[:preferredUsername]).to eq 'openedgroup'
    expect(body[:publicKey]).to be_present
    expect(body[:summary]).to include('A public group')

    get "/api/v1/accounts/#{group.id}"
    expect(response).to have_http_status(200)
    rest = body_as_json
    expect(rest[:group]).to be true
    expect(rest[:acct]).to eq 'openedgroup'
    expect(rest[:username]).to eq 'openedgroup'

    get "/api/v1/timelines/group/#{group.id}"
    expect(response).to have_http_status(200)
    expect(body_as_json.map { |item| item[:id] }).to include(status.id.to_s)

    context = PostingContext::DiscoveryService.new.call(group)
    expect(context[:context][:key]).to eq "builtin:fedibird-group:#{group.id}"

    directory = Account.discoverable.groups
    expect(directory).to include(group)
  end

  it 'does not let a server administrator open another person request icon through the settings route' do
    request = GroupCreationRequest.create!(
      requester_account: requester.account,
      username: 'hiddenicon',
      display_name: 'Hidden',
      note: 'no'
    )
    sign_in reviewer
    get "/settings/group_creation_requests/#{request.id}/icon"
    expect(response).to have_http_status(404)
  end
end
