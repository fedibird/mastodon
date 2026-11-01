# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NodeInfoSoftwareLookup do
  before { described_class.reset! }

  def node_queries
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      queries << sql if sql.include?('nodes')
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      yield
    end

    queries
  end

  def remote_account(domain, username: 'alice')
    Fabricate(
      :account,
      username: username,
      domain: domain,
      uri: "https://#{domain}/users/#{username}",
      url: "https://elsewhere.example/@#{username}"
    )
  end

  it 'returns the NodeInfo software document and ignores info and info_override' do
    remote_account('remote.example')
    Node.create!(
      domain: 'remote.example',
      info: { 'software_name' => 'mastodon', 'software_version' => '9.9.9', 'upstream_name' => 'mastodon' },
      info_override: { 'software_name' => 'mastodon', 'software_version' => '9.9.9' },
      nodeinfo: { 'software' => { 'name' => 'pleroma', 'version' => '2.4.2' } },
      last_fetched_at: Time.now.utc
    )

    expect(UpdateNodeService).not_to receive(:new)
    expect(described_class.read('remote.example')).to eq(
      'name' => 'pleroma',
      'version' => '2.4.2',
      'domain' => 'remote.example'
    )
  end

  it 'returns nil when NodeInfo was not stored or reported an error' do
    remote_account('missing.example')
    remote_account('broken.example')
    remote_account('empty.example')
    Node.create!(domain: 'missing.example', info: { 'software_name' => 'mastodon', 'software_version' => '4.2.1' }, nodeinfo: { 'error' => 'missing' }, last_fetched_at: Time.now.utc)
    Node.create!(domain: 'broken.example', nodeinfo: { 'error' => 'timeout', 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)
    Node.create!(domain: 'empty.example', nodeinfo: { 'software' => { 'name' => '  ', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)

    expect(described_class.read('missing.example')).to be_nil
    expect(described_class.read('broken.example')).to be_nil
    expect(described_class.read('empty.example')).to be_nil
    expect(described_class.read('absent.example')).to be_nil
    expect(described_class.read(nil)).to be_nil
    expect(described_class.read('not a host')).to be_nil
  end

  it 'loads every domain in one query and does not query again' do
    first = remote_account('one.example', username: 'ann')
    second = remote_account('two.example', username: 'ben')
    Node.create!(domain: 'one.example', nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)
    Node.create!(domain: 'two.example', nodeinfo: { 'software' => { 'name' => 'fedibird', 'version' => '0.1' } }, last_fetched_at: Time.now.utc)

    queries = node_queries { described_class.preload_records([first, second]) }

    expect(queries.size).to eq(1)
    expect(queries.first).to include('nodeinfo')
    expect(node_queries { described_class.read('one.example') }).to be_empty
    expect(node_queries { described_class.read('two.example') }).to be_empty
    expect(described_class.read('one.example')).to include('name' => 'mastodon', 'domain' => 'one.example')
    expect(described_class.read('two.example')).to include('name' => 'fedibird', 'version' => '0.1')
  end

  it 'does not raise when the lookup fails' do
    allow(Node).to receive(:where).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect(described_class.read('remote.example')).to be_nil
    expect(described_class.read('remote.example')).to be_nil
    expect(Node).to have_received(:where).once
  end
end
