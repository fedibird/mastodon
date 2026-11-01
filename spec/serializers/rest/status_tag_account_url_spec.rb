# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'REST status tag account_url' do
  def node_queries
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      queries << sql if sql.include?('{software,name}')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries
  end

  def remote_account(domain, username: 'alice')
    Fabricate(
      :account,
      username: username,
      domain: domain,
      uri: "https://#{domain}/users/#{username}",
      url: "https://#{domain}/@#{username}"
    )
  end

  def tagged_status(account, name)
    status = Fabricate(:status, account: account)
    status.tags << Tag.find_or_create_by!(name: name)
    status
  end

  def status_json(status, **options)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        status,
        serializer: REST::StatusSerializer,
        scope: nil,
        scope_name: :current_user,
        **options
      ).to_json,
      symbolize_names: true
    )
  end

  it 'adds account_url from cached NodeInfo and leaves tags[].url unchanged' do
    account = remote_account('remote.example')
    Node.create!(
      domain: 'remote.example',
      info: { 'software_name' => 'pleroma', 'software_version' => '9.9.9', 'upstream_name' => 'mastodon' },
      info_override: { 'software_name' => 'mastodon', 'software_version' => '9.9.9' },
      nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } },
      last_fetched_at: Time.now.utc
    )
    status = tagged_status(account, 'rails')

    expect(UpdateNodeService).not_to receive(:new)
    body = status_json(status)
    tag = body[:tags].find { |item| item[:name] == 'rails' }

    expect(tag[:url]).to include('/tags/rails')
    expect(tag[:account_url]).to eq('https://remote.example/@alice/tagged/rails')
  end

  it 'omits account_url when NodeInfo is missing, errored, overridden, or for another host' do
    missing = remote_account('missing.example', username: 'mia')
    errored = remote_account('errored.example', username: 'ed')
    shifted = Fabricate(:account, username: 'sam', domain: 'acct.example', uri: 'https://acct.example/users/sam', url: 'https://web.example/@sam')
    Node.create!(domain: 'errored.example', info: { 'software_name' => 'mastodon', 'software_version' => '4.2.1' }, nodeinfo: { 'error' => 'timeout', 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)
    Node.create!(domain: 'acct.example', nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)

    expect(status_json(tagged_status(missing, 'rails'))[:tags].first).not_to have_key(:account_url)
    expect(status_json(tagged_status(errored, 'rails'))[:tags].first).not_to have_key(:account_url)
    expect(status_json(tagged_status(shifted, 'rails'))[:tags].first).not_to have_key(:account_url)
  end

  it 'uses the original author for a boost and the quoted author for a quote' do
    original_account = remote_account('original.example', username: 'orig')
    booster = Fabricate(:account, username: 'boosty')
    quoted_account = remote_account('quoted.example', username: 'quot')
    Node.create!(domain: 'original.example', nodeinfo: { 'software' => { 'name' => 'fedibird', 'version' => '0.1' } }, last_fetched_at: Time.now.utc)
    Node.create!(domain: 'quoted.example', nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.3.1' } }, last_fetched_at: Time.now.utc)
    original = tagged_status(original_account, 'photo')
    quoted = tagged_status(quoted_account, 'photo')
    boost = Fabricate(:status, account: booster, reblog: original)
    quoter = tagged_status(Fabricate(:account, username: 'localquoter'), 'localtag')
    quoter.update!(quote: quoted)

    boost_json = status_json(boost)
    quote_json = status_json(quoter)

    expect(boost_json[:tags]).to eq([])
    expect(boost_json.dig(:reblog, :tags).find { |tag| tag[:name] == 'photo' }[:account_url]).to eq('https://original.example/@orig/tagged/photo')
    expect(quote_json[:tags].find { |tag| tag[:name] == 'localtag' }[:account_url]).to end_with('/@localquoter/tagged/localtag')
    expect(quote_json.dig(:quote, :tags).find { |tag| tag[:name] == 'photo' }[:account_url]).to eq('https://quoted.example/@quot/tagged/photo')
  end

  it 'does not add account_url on the shared tag serializers' do
    tag = Tag.find_or_create_by!(name: 'rails')

    status_tag = JSON.parse(ActiveModelSerializers::SerializableResource.new(tag, serializer: REST::StatusSerializer::TagSerializer, scope: nil, scope_name: :current_user).to_json, symbolize_names: true)
    list_tag = JSON.parse(ActiveModelSerializers::SerializableResource.new(tag, serializer: REST::TagSerializer, scope: nil, scope_name: :current_user).to_json, symbolize_names: true)

    expect(status_tag.keys).to include(:name, :url)
    expect(status_tag).not_to have_key(:account_url)
    expect(list_tag).not_to have_key(:account_url)
  end

  it 'reads nodes once for a collection whose domain count grows' do
    statuses = Array.new(4) do |index|
      domain = "peer-#{index}.example"
      Node.create!(domain: domain, nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)
      tagged_status(remote_account(domain, username: "user#{index}"), 'rails')
    end
    quoted = tagged_status(remote_account('quoted-batch.example', username: 'quot'), 'rails')
    Node.create!(domain: 'quoted-batch.example', nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)
    statuses << Fabricate(:status, account: Fabricate(:account, username: 'wrapper'), reblog: statuses.first, quote: quoted)

    queries = node_queries do
      relationships = StatusRelationshipsPresenter.new(statuses, nil)
      statuses.each do |status|
        REST::StatusSerializer.new(status, relationships: relationships, scope: nil, scope_name: :current_user).serializable_hash
      end
    end

    expect(queries.size).to eq(1)
  end

  it 'does not repeat the single-status fallback across a prefetched collection' do
    statuses = Array.new(3) do |index|
      domain = "solo-#{index}.example"
      Node.create!(domain: domain, nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.0' } }, last_fetched_at: Time.now.utc)
      tagged_status(remote_account(domain, username: "solo#{index}"), 'rails')
    end
    pages = nil
    prefetch_queries = node_queries { pages = AccountTagPage::Pages.prefetch(statuses) }
    follow_queries = node_queries do
      statuses.each { |status| REST::StatusSerializer.new(status, account_tag_pages: pages, scope: nil, scope_name: :current_user).serializable_hash }
    end

    expect(prefetch_queries.size).to eq(1)
    expect(follow_queries).to be_empty
  end

  it 'still renders the status when the node lookup fails' do
    account = remote_account('remote.example')
    status = tagged_status(account, 'rails')
    allow(Node).to receive(:where).and_raise(ActiveRecord::ConnectionNotEstablished)

    body = status_json(status)

    expect(body[:id]).to eq(status.id.to_s)
    expect(body[:tags].first[:name]).to eq('rails')
    expect(body[:tags].first).not_to have_key(:account_url)
  end
end
