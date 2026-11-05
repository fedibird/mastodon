# frozen_string_literal: true

require 'rails_helper'

describe 'Group Directory Elasticsearch API' do
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

  def directory_node(domain, software, nodeinfo: { 'ok' => true })
    Node.create!(
      domain: domain,
      info: software.nil? ? {} : { 'software_name' => software },
      nodeinfo: nodeinfo
    )
  end

  def ids
    body_as_json.pluck(:id)
  end

  def sql_ids(params = {}, viewer: user.account, limit: 20)
    GroupDirectory::Query.new(viewer: viewer, params: params, limit: limit).results.map { |account| account.id.to_s }
  end

  def es_ids(params = {}, limit: 20, extra_headers: headers)
    get '/api/v1/group_directory', headers: extra_headers, params: params.merge(limit: limit)
    expect(response).to have_http_status(200), response.body
    ids
  end

  def capture_sql
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries.reject { |sql| sql.match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i) }
  end

  def term_id_values(request)
    found = []
    walk = lambda do |node|
      case node
      when Hash
        terms = node[:terms] || node['terms']
        found.concat(Array(terms[:id] || terms['id'])) if terms.is_a?(Hash)
        node.each_value { |child| walk.call(child) }
      when Array
        node.each { |child| walk.call(child) }
      end
    end
    walk.call(request[:body])
    found
  end

  def stub_ordered_hits(accounts)
    hits = accounts.each_with_index.map { |account, index| { '_id' => account.id.to_s, 'sort' => [index] } }
    allow(Chewy.client).to receive(:search) do |request|
      body = request[:body]
      cursor = body[:search_after]
      start = 0
      if cursor
        found = hits.index { |hit| hit['sort'] == cursor }
        start = found ? found + 1 : hits.length
      end
      { 'hits' => { 'hits' => hits.slice(start, body[:size]) } }
    end
  end

  describe 'when GROUP_DIRECTORY_ES_SEARCH is on' do
    let(:index) { GroupDirectoryEsIndex.new }

    around do |example|
      previous_search = ENV['GROUP_DIRECTORY_ES_SEARCH']
      previous_index = ENV['GROUP_DIRECTORY_INDEX']
      ENV['GROUP_DIRECTORY_ES_SEARCH'] = 'true'
      ENV['GROUP_DIRECTORY_INDEX'] = 'true'
      example.run
    ensure
      ENV['GROUP_DIRECTORY_ES_SEARCH'] = previous_search if previous_search
      ENV.delete('GROUP_DIRECTORY_ES_SEARCH') if previous_search.nil?
      ENV['GROUP_DIRECTORY_INDEX'] = previous_index if previous_index
      ENV.delete('GROUP_DIRECTORY_INDEX') if previous_index.nil?
    end

    before do
      allow(Chewy).to receive(:enabled?).and_return(true)
      allow(GroupDirectory::Indexing).to receive(:index_ready?).and_return(true)
      allow(GroupDirectory::Indexing).to receive(:backfill_complete?).and_return(true)
      allow(GroupDirectory::Indexing).to receive(:version_gap?).and_return(false)
      allow(GroupDirectory::Indexing).to receive(:enqueue)
      allow(Chewy.client).to receive(:open_point_in_time) { |*| index.open_point_in_time }
      allow(Chewy.client).to receive(:close_point_in_time) { |*| index.close_point_in_time }
      allow(Chewy.client).to receive(:search) do |request|
        index.requests << request
        index.search(request)
      end
    end

    it 'matches the SQL rows for search, filters, sort, and pages' do
      directory_node('lemmy.example', 'lemmy')
      directory_node('blank.example', '   ')
      directory_node('bird.example', 'FediBird')
      directory_node('guppe.example', 'guppe')
      photo = directory_group('camera_group', display_name: '写真サークル', note: '街歩きと撮影')
      books = directory_group('book_group', display_name: 'Book Club', note: '本の話')
      remote = directory_group('Walkers', domain: 'lemmy.example', display_name: 'Walkers')
      literal = directory_group('percentgroup', display_name: '100%_done')
      solo = directory_group('a', display_name: 'solo')
      quote = directory_group('quote_group', display_name: "rock 'n' roll")
      unknown = directory_group('unknown_group', domain: 'blank.example')
      fedibird = directory_group('bird_group', domain: 'bird.example')
      other = directory_group('guppe_group', domain: 'guppe.example')
      local = directory_group('my_group')
      bilingual = directory_group('bilingual_group')
      GroupLanguage.create!(account: bilingual, tag: 'ja')
      GroupLanguage.create!(account: bilingual, tag: 'en-US')
      quiet = directory_group('quiet_group')
      declared = directory_group('declared_remote', domain: 'lemmy.example')
      GroupLanguage.create!(account: declared, tag: 'ja')
      Fabricate(:follow, account: user.account, target_account: remote)
      Fabricate(:follow, account: user.account, target_account: photo)
      same_time = 2.hours.ago
      photo.account_stat.update!(last_status_at: same_time)
      books.account_stat.update!(last_status_at: same_time)
      remote.account_stat.update!(last_status_at: 3.days.ago)
      books.update_column(:created_at, 10.years.ago)

      [
        {},
        { q: '撮影' },
        { q: '  book  ' },
        { q: 'walkers@lemmy.example' },
        { q: '@Walkers' },
        { q: "@camera_group@#{Rails.configuration.x.local_domain}" },
        { q: '100%_done' },
        { q: '_d' },
        { q: '%' },
        { q: 'a' },
        { q: "rock 'n' roll" },
        { q: 'lemmy.example' },
        { software: 'lemmy' },
        { software: 'unknown' },
        { software: 'fedibird' },
        { software: 'other' },
        { scope: 'local' },
        { scope: 'following' },
        { scope: 'local', software: 'lemmy' },
        { language: 'ja' },
        { language: 'en-us' },
        { language: 'unset' },
        { language: 'all' },
        { order: 'active' },
        { order: 'new', limit: 2 },
        { order: 'active', limit: 2, offset: '2' },
      ].each do |params|
        limit = params[:limit] || 20
          left = es_ids(params, limit: limit)
          right = sql_ids(params, limit: limit)
          expect(left).to eq(right), "#{params.inspect}\nES #{left.inspect}\nSQL #{right.inspect}"
      end

      expect([local, unknown, fedibird, other, solo, quote, quiet, bilingual, declared].map(&:id)).to all(be_positive)
    end

    it 'keeps blocks, mutes, domain blocks, and ineligible groups out of a stale index page' do
      directory_node('ok.example', 'lemmy')
      directory_node('blocked.example', 'lemmy')
      directory_node('video.example', 'PeerTube')
      visible = directory_group('visible_group', display_name: 'Visible')
      second = directory_group('second_group', display_name: 'Second')
      blocked = directory_group('blocked_group')
      muted = directory_group('muted_group')
      remote = directory_group('remote_group', domain: 'blocked.example')
      allowed = directory_group('allowed_remote', domain: 'ok.example')
      hidden = directory_group('hidden_group', discoverable: false)
      peertube = directory_group('channel', domain: 'video.example')
      suspended = directory_group('suspended_group', suspended: true)
      silenced = directory_group('silenced_group', silenced: true)
      moved = directory_group('moved_group')
      moved.update!(moved_to_account: directory_group('moved_target'))
      unapproved = directory_group('unapproved_group')
      unapproved.user.update!(approved: false)
      blocker = directory_group('blocker_group')
      Fabricate(:block, account: user.account, target_account: blocked)
      Fabricate(:block, account: blocker, target_account: user.account)
      Fabricate(:mute, account: user.account, target_account: muted)
      Fabricate(:account_domain_block, account: user.account, domain: 'blocked.example')

      stub_ordered_hits([hidden, visible, blocked, muted, remote, peertube, suspended, silenced, moved, unapproved, blocker, allowed, second])

      expect(es_ids({}, limit: 1, extra_headers: headers)).to eq([visible.id.to_s])
      expect(es_ids({ offset: '1' }, limit: 1)).to eq([allowed.id.to_s])
      expect(es_ids({ offset: '2' }, limit: 2)).to eq([second.id.to_s])
      expect(response.body).not_to include('private_key')
      row = body_as_json.first
      expect(row[:group]).to be true
      expect(row.dig(:group_directory, :software)).to eq('fedibird')
      expect(row.dig(:group_directory, :capabilities, :posting)).to be_nil
    end

    it 'drops a stale handle or a query that is only split across fields' do
      renamed = directory_group('newname', display_name: 'New')
      token = "#{'0123456789abcdefghij'}TAIL"
      split = directory_group('split_group', display_name: token[0, 20], note: token[5, 20])
      whole = directory_group('whole_group', note: "prefix #{token} suffix")
      stub_ordered_hits([renamed, split, whole])

      expect(es_ids({ q: '@oldname' })).to eq([])
      expect(es_ids({ q: token })).to eq([whole.id.to_s])
      expect(es_ids({ q: '@newname' })).to eq([renamed.id.to_s])
    end

    it 'does not find text past the indexed note or inside an HTML tag, and does fold width' do
      tail = 'TAILTOKEN'
      long = directory_group('long_group')
      long.update_column(:note, ('a' * GroupDirectory::Document::NOTE_LIMIT) + tail)
      tagged = directory_group('tagged_group', note: '<secret-tag>visible words</secret-tag>')
      wide = directory_group('wide_group', display_name: "\uFF23\uFF41\uFF46\u00E9")

      expect(sql_ids({ q: tail })).to eq([long.id.to_s])
      expect(es_ids({ q: tail })).to eq([])
      expect(sql_ids({ q: '<secret-tag>' })).to eq([tagged.id.to_s])
      expect(es_ids({ q: '<secret-tag>' })).to eq([])
      expect(sql_ids({ q: 'cafe' })).to eq([])
      expect(es_ids({ q: 'cafe' })).to eq([wide.id.to_s])
      expect(es_ids({ q: 'visible words' })).to eq([tagged.id.to_s])
    end

    it 'chunks follow ids and still rechecks them in PostgreSQL' do
      stub_const('GroupDirectory::FollowingSearch::CHUNK', 2)
      targets = Array.new(5) { |index| directory_group("followed_#{index}") }
      targets.each { |account| Fabricate(:follow, account: user.account, target_account: account) }
      stranger = directory_group('stranger_group')

      expected = sql_ids({ scope: 'following' })
      queries = capture_sql { expect(es_ids({ scope: 'following' })).to eq(expected) }
      chunks = index.requests.map { |request| term_id_values(request) }
      expect(chunks).to all(satisfy { |ids| ids.size.between?(1, 2) })
      expect(chunks.flatten.map(&:to_i).sort).to eq(targets.map(&:id).sort)
      expect(chunks.flatten.map(&:to_i)).not_to include(stranger.id)
      expect(index.requests.map { |request| request[:body].to_s }.join).not_to include('query_string')
      expect(queries.grep(/ILIKE/i)).to be_empty
      follow_sql = queries.select { |sql| sql.include?('follows') }
      expect(follow_sql.grep(/ IN /).size).to eq(1), follow_sql.inspect
      expect(follow_sql.grep(/LIMIT/)).to be_empty
      expect(queries.count { |sql| sql.include?('"blocks"') }).to be <= 2
      expect(queries.count { |sql| sql.include?('"mutes"') }).to be <= 1
    end

    it 'fails closed instead of sending a huge follow set' do
      stub_const('GroupDirectory::FollowingSearch::MAX_FOLLOW_IDS', 2)
      3.times do |index|
        account = directory_group("many_follow_#{index}")
        Fabricate(:follow, account: user.account, target_account: account)
      end
      expect(Chewy.client).not_to receive(:search)
      expect(Chewy.client).not_to receive(:open_point_in_time)

      get '/api/v1/group_directory', headers: headers, params: { scope: 'following' }

      expect(response).to have_http_status(503)
      expect(body_as_json[:error]).to eq('Group directory search is temporarily unavailable')
    end

    it 'drops a group whose current software, language, or locality no longer matches' do
      directory_node('shifted.example', 'lemmy')
      remote = directory_group('shifted_group', domain: 'shifted.example', display_name: 'Shifted')
      GroupLanguage.create!(account: remote, tag: 'en')
      Node.find_by!(domain: 'shifted.example').update!(info: { 'software_name' => 'piefed' })
      local = directory_group('local_kept', display_name: 'Local')
      stub_ordered_hits([remote, local])

      expect(es_ids({ software: 'lemmy' })).to eq([])
      expect(es_ids({ software: 'piefed' })).to eq([remote.id.to_s])
      expect(body_as_json.first.dig(:group_directory, :software)).to eq('piefed')
      expect(es_ids({ language: 'ja' })).to eq([])
      expect(es_ids({ language: 'en' })).to eq([remote.id.to_s])
      expect(body_as_json.first.dig(:group_directory, :languages)).to eq(['en'])
      expect(es_ids({ language: 'unset' })).to eq([local.id.to_s])
      expect(es_ids({ scope: 'local' })).to eq([local.id.to_s])
    end

    it 'keeps a group whose activity moves after the point in time opens' do
      older = directory_group('older_group')
      newer = directory_group('newer_group')
      older.account_stat.update!(last_status_at: 3.days.ago)
      newer.account_stat.update!(last_status_at: 1.hour.ago)
      stub_const('GroupDirectory::CandidatePage::BATCH', 1)
      index.after_first_search = lambda do
        older.account_stat.update!(last_status_at: Time.now.utc)
      end

      expect(es_ids({}, limit: 2)).to eq([newer.id.to_s, older.id.to_s])
      expect(index.requests).to all(satisfy { |request| request.dig(:body, :pit, :id).present? })
      expect(index.closed).to be >= 1
    end

    it 'does not repeat group, node, or block reads per row' do
      3.times { |index| directory_group("listed_#{index}") }
      GroupLanguage.create!(account: Account.find_by!(username: 'listed_0'), tag: 'ja')

      expected = sql_ids
      queries = capture_sql { expect(es_ids).to eq(expected) }
      expect(queries.grep(/ILIKE/i)).to be_empty
      id_scoped = queries.select { |sql| sql.include?('"accounts"."id" IN') }
      expect(id_scoped).not_to be_empty
      expect(queries.grep(/"group_languages"\."account_id" = \$/)).to be_empty
      expect(queries.grep(/"nodes"\."domain" = \$/)).to be_empty
      expect(queries.count { |sql| sql.include?('"blocks"') }).to be <= 2
      expect(queries.count { |sql| sql.include?('"mutes"') }).to be <= 1
      follow_sql = queries.select { |sql| sql.include?('FROM "follows"') }
      expect(follow_sql).to be_empty
    end

    it 'keeps a managed local group with no login and rejects a login-less group without one' do
      requester = Fabricate(:user)
      request = GroupCreationRequest.create!(
        requester_account: requester.account,
        username: 'managedonly',
        display_name: 'Managed',
        note: 'A place'
      )
      managed = Fabricate(:account, username: 'managedonly', actor_type: 'Group', discoverable: true, display_name: 'Managed')
      managed.create_account_stat!
      ManagedGroup.create!(account: managed, origin: :approved_request, creation_request: request)
      orphan = Fabricate(:account, username: 'orphanlocal', actor_type: 'Group', discoverable: true)
      orphan.create_account_stat!
      stub_ordered_hits([orphan, managed])

      expect(es_ids).to eq([managed.id.to_s])
      expect(sql_ids).to include(managed.id.to_s)
      expect(sql_ids).not_to include(orphan.id.to_s)
    end

    it 'returns 400 before calling Elasticsearch' do
      expect(Chewy.client).not_to receive(:search)
      get '/api/v1/group_directory', headers: headers, params: { q: 'a' * 101 }

      expect(response).to have_http_status(400)
    end

    it 'returns an empty list for a one-character name, a bad handle, and anonymous following without Elasticsearch' do
      directory_group('neko', display_name: '猫')
      expect(Chewy.client).not_to receive(:search)

      get '/api/v1/group_directory', headers: headers, params: { q: '猫' }
      expect(response).to have_http_status(200)
      expect(body_as_json).to be_empty

      get '/api/v1/group_directory', headers: headers, params: { q: 'walkers@https://evil.example' }
      expect(response).to have_http_status(200)
      expect(body_as_json).to be_empty

      get '/api/v1/group_directory', params: { scope: 'following' }
      expect(response).to have_http_status(200)
      expect(body_as_json).to be_empty
    end

    it 'fails closed when the index is not ready, the version gap is set, or Elasticsearch errors' do
      directory_group('visible_group')
      expect(GroupDirectory::Query).not_to receive(:new)

      allow(GroupDirectory::Indexing).to receive(:index_ready?).and_return(false)
      get '/api/v1/group_directory', headers: headers
      expect(response).to have_http_status(503)
      expect(body_as_json[:error]).to eq('Group directory search is temporarily unavailable')
      expect(response.body).not_to include('index is missing')

      allow(GroupDirectory::Indexing).to receive(:index_ready?).and_return(true)
      allow(GroupDirectory::Indexing).to receive(:backfill_complete?).and_return(false)
      get '/api/v1/group_directory', headers: headers
      expect(response).to have_http_status(503)
      expect(response.body).not_to include('backfill')

      allow(GroupDirectory::Indexing).to receive(:backfill_complete?).and_return(true)
      allow(GroupDirectory::Indexing).to receive(:version_gap?).and_return(true)
      get '/api/v1/group_directory', headers: headers
      expect(response).to have_http_status(503)
      expect(response.body).not_to include('version gap')

      allow(GroupDirectory::Indexing).to receive(:version_gap?).and_return(false)
      allow(Chewy.client).to receive(:search).and_raise(Faraday::ConnectionFailed.new('down'))
      get '/api/v1/group_directory', headers: headers
      expect(response).to have_http_status(503)

      allow(Chewy.client).to receive(:search).and_return('timed_out' => true, 'hits' => { 'hits' => [{ '_id' => '1', 'sort' => [1] }] })
      get '/api/v1/group_directory', headers: headers
      expect(response).to have_http_status(503)
      expect(body_as_json).not_to be_an(Array)
    end

    it 'fails closed when the index flag or Elasticsearch itself is off' do
      expect(GroupDirectory::Query).not_to receive(:new)
      ENV['GROUP_DIRECTORY_INDEX'] = 'false'
      get '/api/v1/group_directory', headers: headers
      expect(response).to have_http_status(503)

      ENV['GROUP_DIRECTORY_INDEX'] = 'true'
      allow(Chewy).to receive(:enabled?).and_return(false)
      get '/api/v1/group_directory', headers: headers
      expect(response).to have_http_status(503)
    end
  end

  it 'keeps the SQL directory when the search flag is off' do
    listed = directory_group('sql_group', display_name: 'SQL path')
    allow(Chewy.client).to receive(:search).and_raise(Faraday::ConnectionFailed.new('down'))

    get '/api/v1/group_directory', headers: headers

    expect(response).to have_http_status(200)
    expect(ids).to eq([listed.id.to_s])
    expect(GroupDirectory::Readiness.search_enabled?).to be false
    sample = File.read(Rails.root.join('.env.production.sample'))
    expect(sample).to include('# GROUP_DIRECTORY_ES_SEARCH=true')
    expect(sample).not_to match(/^GROUP_DIRECTORY_ES_SEARCH=true/)
    expect(File.read(Rails.root.join('docs/group_directory_es_search.md'))).to include('503')
  end
end
