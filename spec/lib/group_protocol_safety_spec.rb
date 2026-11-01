# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupProtocol do
  def remote_group(domain, **attrs)
    Fabricate(
      :account,
      {
        username: 'group',
        domain: domain,
        actor_type: 'Group',
        protocol: :activitypub,
        uri: "https://#{domain}/users/group",
        inbox_url: "https://#{domain}/inbox",
      }.merge(attrs)
    )
  end

  def capture_sql
    sqls = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
      sqls << payload[:sql].to_s
    end
    yield
    sqls
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # Schema reflection is not part of the query budget. Rails issues it once
  # per process, before the column cache is warm, and production boots with
  # that cache already loaded.
  def statement_sql(sqls)
    sqls.reject do |sql|
      sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|SHOW|SET)\b/i) ||
        sql.match?(/\bpg_(?:attribute|attrdef|type|collation|class|namespace|index)\b/)
    end
  end

  def expect_no_network
    expect(Request).not_to receive(:new)
    expect(UpdateNodeService).not_to receive(:new)
    expect(Node).not_to receive(:resolve_domain)
    expect(ResolveAccountService).not_to receive(:new)
    expect(ActivityPub::FetchRemoteAccountService).not_to receive(:new)
    expect(ActivityPub::FetchRemoteKeyService).not_to receive(:new)
    before = request_signature_count
    yield
    expect(request_signature_count).to eq before
  end

  def request_signature_count
    count = 0
    WebMock::RequestRegistry.instance.requested_signatures.each { count += 1 }
    count
  end

  it 'does not fetch, sign, or follow redirects for a hostile stored actor' do
    Node.create!(
      domain: 'group.example',
      info: { 'software_name' => 'fedibird', 'upstream_name' => 'mastodon' },
      nodeinfo: { 'links' => [{ 'href' => 'http://169.254.169.254/latest' }] },
      last_fetched_at: Time.current
    )
    account = remote_group(
      'group.example',
      uri: 'https://evil.test/users/group',
      inbox_url: 'http://127.0.0.1/inbox',
      url: 'http://0177.0.0.1/users/group'
    )

    result = nil
    expect_no_network { result = described_class.assess(account) }

    expect(result[:implementation][:evidence]).to include(uncertainty: 'actor_mismatch')
    expect(result[:remote_fedibird]).to eq 'not_determined'
    expect(result[:authorizes_posting]).to be false
  end

  it 'adds no queries for a preloaded remote group and only indexed lookups for a local viewer' do
    accounts = Array.new(20) do |index|
      domain = "load#{index}.example"
      Node.create!(
        domain: domain,
        info: { 'software_name' => 'fedibird', 'upstream_name' => 'mastodon' },
        nodeinfo: { 'software' => { 'name' => 'fedibird' } },
        last_fetched_at: Time.current
      )
      remote_group(domain, username: "group#{index}", uri: "https://#{domain}/users/group#{index}")
    end
    loaded = Account.where(id: accounts.map(&:id)).includes(:node).to_a
    local = Fabricate(:account, username: 'loadlocal', actor_type: 'Group')
    viewer = Fabricate(:account, username: 'loadviewer')

    remote_sql = statement_sql(capture_sql { loaded.each { |account| described_class.assess(account) } })
    local_sql = statement_sql(capture_sql { described_class.assess(local) })
    viewer_sql = statement_sql(capture_sql { described_class.assess(local, viewer: viewer) })

    expect(remote_sql).to eq []
    expect(local_sql).to eq []
    expect(viewer_sql.size).to eq 2
    expect(viewer_sql.join(' ')).to include('follows')
    expect(viewer_sql.join(' ')).to include('group_role_assignments')
    expect(viewer_sql.join(' ')).not_to include('group_affiliations')
  end

  it 'reads one affiliation query only while that snapshot is fresh' do
    Node.create!(
      domain: 'aff-load.example',
      info: { 'software_name' => 'mitra' },
      nodeinfo: { 'software' => { 'name' => 'mitra' } },
      last_fetched_at: Time.current
    )
    group = remote_group('aff-load.example')
    viewer = Fabricate(:account, username: 'affviewer', domain: 'home.example', uri: 'https://home.example/users/affviewer', protocol: :activitypub)
    group.update_columns(
      affiliations_url: 'https://aff-load.example/affiliations',
      affiliations_fetched_at: nil,
      permission_definitions_fetched_at: nil
    )
    loaded = Account.where(id: group.id).includes(:node).first

    unfetched_sql = statement_sql(capture_sql { described_class.assess(loaded, viewer: viewer) })
    group.update_columns(affiliations_fetched_at: Time.current, permission_definitions_fetched_at: Time.current, can_create_affiliation: 'member')
    GroupAffiliation.create!(group_account: group, subject_uri: viewer.uri, relationship: 'member')
    loaded = Account.where(id: group.id).includes(:node).first
    fresh_sql = statement_sql(capture_sql { described_class.assess(loaded, viewer: viewer) })

    expect(unfetched_sql).to eq []
    expect(fresh_sql.size).to eq 1
    expect(fresh_sql.first).to include('group_affiliations')
    expect(fresh_sql.first).not_to include('follows')
  end

  it 'does not consult follow or role rows for a remote viewer' do
    group = remote_group('quiet.example')
    viewer = Fabricate(:account, username: 'quietviewer')
    expect(viewer).not_to receive(:following?)
    expect(GroupRoleAssignment).not_to receive(:active)

    result = described_class.assess(group, viewer: viewer)

    expect(result[:viewer_capabilities].map { |row| row[:name] }).to eq described_class::VIEWER_CAPABILITIES
    expect(result[:viewer_capabilities].find { |row| row[:name] == 'membership_follow' }).to include(state: 'unknown', value: nil)
  end
end
