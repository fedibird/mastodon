# frozen_string_literal: true

require 'rails_helper'

describe 'Group Directory API' do
  let(:user) { Fabricate(:user, confirmed_at: 10.days.ago, approved: true) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

  def directory_group(username, domain: nil, **options)
    local_user = domain.nil? ? Fabricate(:user, confirmed_at: 10.days.ago, approved: true) : nil
    account = Fabricate(:account, {
      username: username,
      domain: domain,
      actor_type: 'Group',
      discoverable: true,
      display_name: options.delete(:display_name) || username,
      note: options.delete(:note) || '',
      user: local_user,
    }.merge(options))
    account.create_account_stat!
    account
  end

  def directory_node(domain, software, nodeinfo: {})
    Node.create!(
      domain: domain,
      info: software.nil? ? {} : { 'software_name' => software },
      nodeinfo: nodeinfo
    )
  end

  def ids
    body_as_json.pluck(:id)
  end

  it 'returns an Account array and keeps unknown groups while excluding known PeerTube channels' do
    directory_node('lemmy.example', 'Lemmy')
    directory_node('video.example', 'PeerTube')
    directory_node('blank.example', '')
    directory_node('missing.example', 'mastodon', nodeinfo: { 'error' => 'missing' })
    directory_node('guppe.example', 'guppe')
    local = directory_group('local_group', display_name: '写真サークル', note: '<p>街歩き</p>')
    lemmy = directory_group('lemmy_group', domain: 'lemmy.example', note: '<script>alert(1)</script><p>hello</p>')
    directory_group('channel', domain: 'video.example')
    blank = directory_group('blank_group', domain: 'blank.example')
    directory_group('missing_group', domain: 'missing.example')
    guppe = directory_group('guppe_group', domain: 'guppe.example')
    directory_group('person_not_group', domain: 'lemmy.example', actor_type: 'Person')
    directory_group('hidden_group', discoverable: false)
    directory_group('undiscoverable_remote', domain: 'lemmy.example', discoverable: nil)

    get '/api/v1/group_directory', headers: headers

    expect(response).to have_http_status(200)
    expect(body_as_json).to be_an(Array)
    expect(ids).to contain_exactly(local.id.to_s, lemmy.id.to_s, blank.id.to_s, guppe.id.to_s)
    lemmy_row = body_as_json.find { |row| row[:id] == lemmy.id.to_s }
    local_row = body_as_json.find { |row| row[:id] == local.id.to_s }
    blank_row = body_as_json.find { |row| row[:id] == blank.id.to_s }
    expect(lemmy_row[:group]).to be true
    expect(lemmy_row[:username]).to eq('lemmy_group')
    expect(lemmy_row[:acct]).to eq('lemmy_group@lemmy.example')
    expect(lemmy_row.dig(:group_directory, :software)).to eq('lemmy')
    expect(lemmy_row.dig(:group_directory, :languages)).to eq([])
    expect(lemmy_row.dig(:group_directory, :capabilities, :posting)).to be_nil
    expect(local_row.dig(:group_directory, :software)).to eq('fedibird')
    expect(blank_row.dig(:group_directory, :software)).to be_nil
    expect(response.body).not_to include('<script')
    expect(response.body).not_to include('private_key')
    expect(response.body).not_to include('BEGIN ')
    expect(GroupDirectory::Query.new(viewer: nil, params: {}, limit: 20).results.to_sql).not_to match(/JOIN ["']?nodes/i)
  end

  it 'filters name, handle, and description without treating SQL wildcards as patterns' do
    photo = directory_group('camera_group', display_name: '写真サークル', note: '街歩きと撮影')
    books = directory_group('book_group', display_name: 'Book Club', note: '本の話')
    directory_node('lemmy.example', 'lemmy')
    remote = directory_group('walkers', domain: 'lemmy.example', display_name: 'Walkers')

    get '/api/v1/group_directory', headers: headers, params: { q: '撮影' }
    expect(ids).to eq([photo.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { q: '  book  ' }
    expect(ids).to eq([books.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { q: 'walkers@lemmy.example' }
    expect(ids).to eq([remote.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { q: 'lemmy.example' }
    expect(ids).to eq([remote.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { q: "%_not_present" }
    expect(body_as_json).to be_empty

    get '/api/v1/group_directory', headers: headers, params: { q: "  " }
    expect(ids).to contain_exactly(photo.id.to_s, books.id.to_s, remote.id.to_s)

    directory_group('quote_group', display_name: "rock 'n' roll <&>")
    get '/api/v1/group_directory', headers: headers, params: { q: "rock 'n' roll" }
    expect(ids.size).to eq(1)
  end

  it 'filters by local scope, software, unknown, other, and followed groups' do
    directory_node('lemmy.example', 'lemmy')
    directory_node('blank.example', '   ')
    directory_node('bird.example', 'FediBird')
    directory_node('guppe.example', 'guppe')
    local = directory_group('my_group')
    remote = directory_group('lemmy_group', domain: 'lemmy.example')
    unknown = directory_group('unknown_group', domain: 'blank.example')
    fedibird = directory_group('bird_group', domain: 'bird.example')
    other = directory_group('guppe_group', domain: 'guppe.example')
    Fabricate(:follow, account: user.account, target_account: remote)
    Fabricate(:follow, account: user.account, target_account: directory_group('outside', domain: 'lemmy.example', discoverable: false))

    get '/api/v1/group_directory', headers: headers, params: { scope: 'local' }
    expect(ids).to eq([local.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { software: 'Lemmy' }
    expect(ids).to eq([remote.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { software: 'unknown' }
    expect(ids).to eq([unknown.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { software: 'fedibird' }
    expect(ids).to contain_exactly(local.id.to_s, fedibird.id.to_s)

    get '/api/v1/group_directory', headers: headers, params: { software: 'other' }
    expect(ids).to eq([other.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { scope: 'following' }
    expect(ids).to eq([remote.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { scope: 'local', software: 'lemmy' }
    expect(body_as_json).to be_empty
  end

  it 'keeps block, mute, domain block, suspension, silence, move, and unapproved groups out' do
    blocked = directory_group('blocked_group')
    muted = directory_group('muted_group')
    visible = directory_group('visible_group')
    directory_node('blocked.example', 'lemmy')
    directory_node('ok.example', 'lemmy')
    directory_node('video.example', 'PeerTube')
    remote = directory_group('remote_group', domain: 'blocked.example')
    allowed_remote = directory_group('allowed_remote', domain: 'ok.example')
    peertube = directory_group('channel', domain: 'video.example')
    suspended = directory_group('suspended_group', suspended: true)
    silenced = directory_group('silenced_group', silenced: true)
    moved_to = directory_group('moved_target')
    moved = directory_group('moved_group')
    moved.update!(moved_to_account: moved_to)
    unapproved = directory_group('unapproved_group')
    unapproved.user.update!(approved: false)

    Fabricate(:block, account: user.account, target_account: blocked)
    Fabricate(:mute, account: user.account, target_account: muted)
    Fabricate(:account_domain_block, account: user.account, domain: 'blocked.example')

    get '/api/v1/group_directory', headers: headers

    expect(ids).to contain_exactly(visible.id.to_s, moved_to.id.to_s, allowed_remote.id.to_s)
    expect(ids).not_to include(suspended.id.to_s, silenced.id.to_s, moved.id.to_s, unapproved.id.to_s, remote.id.to_s, peertube.id.to_s)
  end

  it 'pages with a stable order and does not treat new as created_at' do
    first = directory_group('first_group')
    second = directory_group('second_group')
    third = directory_group('third_group')
    first.account_stat.update!(last_status_at: 1.hour.ago)
    second.account_stat.update!(last_status_at: 1.hour.ago)
    third.account_stat.update!(last_status_at: 3.days.ago)
    second.update_column(:created_at, 10.years.ago)

    get '/api/v1/group_directory', headers: headers, params: { order: 'active', limit: 2 }
    expect(ids).to eq([second.id.to_s, first.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { order: 'active', limit: 2, offset: '2' }
    expect(ids).to eq([third.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { order: 'new', limit: 2 }
    expect(ids).to eq([third.id.to_s, second.id.to_s])
  end

  it 'filters only explicit group language tags' do
    directory_node('lemmy.example', 'lemmy')
    Node.find_by(domain: 'lemmy.example').update!(info: { 'software_name' => 'lemmy', 'languages' => ['ja'] })
    bilingual = directory_group('bilingual_group')
    bilingual.user.update!(locale: 'en')
    GroupLanguage.create!(account: bilingual, tag: 'ja')
    GroupLanguage.create!(account: bilingual, tag: 'en-US')
    quiet = directory_group('quiet_group')
    node_only = directory_group('node_only', domain: 'lemmy.example')
    declared_remote = directory_group('declared_remote', domain: 'lemmy.example')
    GroupLanguage.create!(account: declared_remote, tag: 'ja')

    get '/api/v1/group_directory', headers: headers, params: { language: 'ja' }
    expect(response).to have_http_status(200)
    expect(ids).to contain_exactly(bilingual.id.to_s, declared_remote.id.to_s)
    row = body_as_json.find { |item| item[:id] == bilingual.id.to_s }
    expect(row.dig(:group_directory, :languages)).to eq(['en-US', 'ja'])

    get '/api/v1/group_directory', headers: headers, params: { language: 'en-us' }
    expect(ids).to eq([bilingual.id.to_s])

    get '/api/v1/group_directory', headers: headers, params: { language: 'unset' }
    expect(ids).to contain_exactly(quiet.id.to_s, node_only.id.to_s)

    get '/api/v1/group_directory', headers: headers, params: { language: 'all' }
    expect(ids).to contain_exactly(bilingual.id.to_s, quiet.id.to_s, node_only.id.to_s, declared_remote.id.to_s)
    expect(GroupDirectory::Query.new(viewer: nil, params: { language: 'ja' }, limit: 20).results.to_sql).not_to match(/JOIN ["']?group_languages/i)
  end

  it 'serves logged-out viewers the public list and an empty following scope' do
    listed = directory_group('public_group')

    get '/api/v1/group_directory'
    expect(response).to have_http_status(200)
    expect(ids).to eq([listed.id.to_s])

    get '/api/v1/group_directory', params: { scope: 'following' }
    expect(response).to have_http_status(200)
    expect(body_as_json).to be_empty
  end

  it 'rejects invalid filters and huge paging input' do
    directory_group('visible_group')

    [
      { q: 'a' * 101 },
      { q: ['array'] },
      { software: 'lemmy;drop' },
      { software: '../lemmy' },
      { scope: 'everything' },
      { order: 'random' },
      { order: ['new'] },
      { offset: '-1' },
      { offset: '100001' },
      { offset: ['1'] },
      { language: '<script>' },
      { language: 'not a tag' },
    ].each do |filter|
      get '/api/v1/group_directory', headers: headers, params: filter
      expect(response).to have_http_status(400), "expected 400 for #{filter.inspect}, got #{response.status} #{response.body}"
    end
  end

  it 'treats software=unknown as NodeInfo with no software name, and still hides missing NodeInfo' do
    directory_node('blank.example', '')
    directory_node('missing.example', '', nodeinfo: { 'error' => 'missing' })
    blank = directory_group('blank_group', domain: 'blank.example')
    missing = directory_group('missing_group', domain: 'missing.example')
    orphan = directory_group('orphan_group', domain: 'orphan.example')
    local = directory_group('local_group')

    get '/api/v1/group_directory', headers: headers, params: { software: 'unknown' }

    expect(response).to have_http_status(200)
    expect(ids).to eq([blank.id.to_s])

    get '/api/v1/group_directory', headers: headers

    expect(ids).to contain_exactly(blank.id.to_s, local.id.to_s)
    expect(ids).not_to include(missing.id.to_s, orphan.id.to_s)
  end

  # enable_seqscan=off only shows the partial index can be used. It does not
  # show that a normal planner picks it, or that note ILIKE is indexed.
  it 'uses the discoverable-group index without multiplying rows through nodes' do
    listed = directory_group('indexed_group')
    relation = GroupDirectory::Query.new(viewer: nil, params: {}, limit: 20).results
    plan = nil

    Account.connection.transaction do
      Account.connection.execute('SET LOCAL enable_seqscan = off')
      plan = Account.connection.exec_query("EXPLAIN #{relation.to_sql}").rows.flatten.join("\n")
    end

    expect(plan).to include('index_accounts_on_discoverable_groups')
    expect(relation.map(&:id)).to eq([listed.id])
    expect(relation.to_sql.scan(/nodes/).size).to be >= 1
    expect(relation.to_sql).not_to match(/JOIN ["']?nodes/i)
  end
end
