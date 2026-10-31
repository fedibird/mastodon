# frozen_string_literal: true

require 'rails_helper'

describe 'Group Directory API' do
  let(:user) { Fabricate(:user, confirmed_at: 10.days.ago, approved: true) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:follows') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

  def make_group(username, domain: nil, display_name: '', note: '', discoverable: true)
    options = {
      username: username,
      domain: domain,
      display_name: display_name,
      note: note,
      actor_type: 'Group',
      discoverable: discoverable,
    }
    options[:user] = Fabricate(:user, confirmed_at: 10.days.ago, approved: true) if domain.nil?

    Fabricate(:account, options).tap(&:create_account_stat!)
  end

  def make_node(domain, software)
    Node.create!(domain: domain, nodeinfo: {}, info: { 'software_name' => software })
  end

  it 'retains public community groups, excludes known PeerTube channels, and returns an Account array' do
    make_node('lemmy.example', 'Lemmy')
    make_node('video.example', 'PeerTube')
    make_node('unknown.example', '')
    local = make_group('my_group')
    lemmy = make_group('lemmy_group', domain: 'lemmy.example')
    make_group('video', domain: 'video.example')
    unknown = make_group('unknown', domain: 'unknown.example')
    make_group('private_group', discoverable: false)

    get '/api/v1/group_directory', headers: headers

    expect(response).to have_http_status(200)
    expect(body_as_json).to be_an(Array)
    expect(body_as_json.pluck(:id)).to contain_exactly(local.id.to_s, lemmy.id.to_s, unknown.id.to_s)
    expect(body_as_json.find { |row| row[:id] == lemmy.id.to_s }.dig(:group_directory, :software)).to eq('lemmy')
    expect(body_as_json.find { |row| row[:id] == local.id.to_s }.dig(:group_directory, :software)).to eq('fedibird')
  end

  it 'filters by name, handle, and description without treating SQL wildcards as patterns' do
    one = make_group('camera_group', display_name: '写真サークル', note: '街歩きと撮影')
    two = make_group('book_group', display_name: '読書会', note: '本の話')
    get '/api/v1/group_directory', headers: headers, params: { q: '撮影' }
    expect(body_as_json.pluck(:id)).to eq([one.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { q: 'book_group' }
    expect(body_as_json.pluck(:id)).to eq([two.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { q: '%_not_present' }
    expect(body_as_json).to be_empty
  end

  it 'filters by local scope, remote software, unknown software, and followed group' do
    make_node('lemmy.example', 'lemmy')
    make_node('unknown.example', '')
    local = make_group('my_group')
    remote = make_group('lemmy_group', domain: 'lemmy.example')
    unknown = make_group('unknown', domain: 'unknown.example')
    Fabricate(:follow, account: user.account, target_account: remote)

    get '/api/v1/group_directory', headers: headers, params: { scope: 'local' }
    expect(body_as_json.pluck(:id)).to eq([local.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { software: 'lemmy' }
    expect(body_as_json.pluck(:id)).to eq([remote.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { software: 'unknown' }
    expect(body_as_json.pluck(:id)).to eq([unknown.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { scope: 'following' }
    expect(body_as_json.pluck(:id)).to eq([remote.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { software: 'fedibird' }
    expect(body_as_json.pluck(:id)).to eq([local.id.to_s])
  end

  it 'preserves account blocking and refuses invalid filter and paging parameters' do
    hidden = make_group('blocked_group')
    visible = make_group('visible_group')
    Fabricate(:block, account: user.account, target_account: hidden)

    get '/api/v1/group_directory', headers: headers
    expect(body_as_json.pluck(:id)).to eq([visible.id.to_s])

    [{ q: 'a' * 101 }, { software: 'lemmy;DROP' }, { scope: 'everything' }, { order: 'random' }, { offset: '-1' }, { offset: '999999' }].each do |filter|
      get '/api/v1/group_directory', headers: headers, params: filter
      expect(response).to have_http_status(400)
    end
  end
end
