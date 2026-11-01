# frozen_string_literal: true

require 'rails_helper'

# Same serializer entry points the controllers use.
RSpec.describe 'account tag page response paths' do
  def remote(domain, username)
    Fabricate(
      :account,
      username: username,
      domain: domain,
      uri: "https://#{domain}/users/#{username}",
      url: "https://#{domain}/@#{username}"
    )
  end

  def tagged(account, name = 'rails')
    status = Fabricate(:status, account: account)
    status.tags << Tag.find_or_create_by!(name: name)
    status
  end

  def node(domain)
    Node.create!(
      domain: domain,
      nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } },
      last_fetched_at: Time.now.utc
    )
  end

  def statuses_for(prefix, size)
    Array.new(size) do |index|
      domain = "#{prefix}-#{index}.example"
      node(domain)
      tagged(remote(domain, "#{prefix}#{index}"))
    end
  end

  def capture
    buckets = Hash.new(0)
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      next if sql.match?(/pg_|SCHEMA|SAVEPOINT/)

      if sql.include?('{software,name}')
        buckets[:software] += 1
      elsif sql.match?(/from\s+"nodes"/i)
        buckets[:nodes] += 1
      end
      buckets[:accounts] += 1 if sql.match?(/from\s+"accounts"/i)
      buckets[:nested] += 1 if sql.include?('WITH RECURSIVE nest')
      buckets[:statuses] += 1 if sql.match?(/from\s+"statuses"/i) && !sql.include?('WITH RECURSIVE nest')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    buckets
  end

  def render_json(resource, **options)
    ActiveModelSerializers::SerializableResource.new(
      resource,
      { scope: nil, scope_name: :current_user }.merge(options)
    ).to_json
  end

  def expect_one_prefetch
    allow(AccountTagPage::Pages).to receive(:prefetch).and_call_original
    yield
    expect(AccountTagPage::Pages).to have_received(:prefetch).once
  end

  it 'prefetches a status collection once, and the software read does not grow with size' do
    small = statuses_for('small', 2)
    large = statuses_for('large', 4)
    small_counts = capture { render_json(small, each_serializer: REST::StatusSerializer, account_tag_pages: AccountTagPage::Pages.prefetch(small)) }
    large_counts = capture { render_json(large, each_serializer: REST::StatusSerializer, account_tag_pages: AccountTagPage::Pages.prefetch(large)) }

    expect(small_counts[:software]).to eq(1)
    expect(large_counts[:software]).to eq(1)
    expect(small_counts[:nested]).to eq(0)
    expect(large_counts[:nested]).to eq(0)
    # Status serialization already loads per-status rows. Doubling the page
    # doubles those SELECTs. The nested-domain walk and the software projection do not.
    expect(large_counts[:statuses]).to eq(small_counts[:statuses] * 2)
    # compute_searchability -> compatible_visibility loads account.node once per
    # remote author. That is separate from the software projection.
    expect(small_counts[:nodes]).to eq(2)
    expect(large_counts[:nodes]).to eq(4)
  end

  it 'prefetches search results once for the whole status list' do
    statuses = statuses_for('search', 3)
    search = Search.new(accounts: [], statuses: statuses, hashtags: [], profiles: [], custom_emojis: [])
    body = nil
    counts = nil

    expect_one_prefetch do
      counts = capture { body = render_json(search, serializer: REST::SearchSerializer) }
    end

    parsed = JSON.parse(body, symbolize_names: true)
    expect(counts[:software]).to eq(1)
    expect(parsed[:statuses].map { |status| status.dig(:tags, 0, :account_url) }).to all(include('/tagged/rails'))
  end

  it 'prefetches notification target statuses once' do
    statuses = statuses_for('note', 3)
    viewer = Fabricate(:account)
    notifications = statuses.map do |status|
      favourite = Favourite.create!(account: viewer, status: status)
      Notification.create!(account: viewer, from_account: status.account, activity: favourite, type: :favourite)
    end
    body = nil
    counts = nil

    expect_one_prefetch do
      counts = capture do
        body = render_json(
          notifications,
          each_serializer: REST::NotificationSerializer,
          relationships: StatusRelationshipsPresenter.new(statuses, nil)
        )
      end
    end

    parsed = JSON.parse(body, symbolize_names: true)
    expect(counts[:software]).to eq(1)
    expect(parsed.map { |note| note.dig(:status, :tags, 0, :account_url) }).to all(include('/tagged/rails'))
  end

  it 'prefetches compact referenced reblogs and quotes once' do
    original = tagged(remote('compact-original.example', 'orig'), 'photo')
    quoted = tagged(remote('compact-quoted.example', 'quot'), 'photo')
    node('compact-original.example')
    node('compact-quoted.example')
    original.update!(quote: quoted)
    page = [Fabricate(:status, account: Fabricate(:account, username: 'booster'), reblog: original)]
    body = nil
    counts = nil

    expect_one_prefetch do
      counts = capture do
        body = render_json(CompactStatusesPresenter.new(statuses: page), serializer: REST::CompactStatusesSerializer)
      end
    end

    parsed = JSON.parse(body, symbolize_names: true)
    referenced = parsed[:referenced_statuses].find { |status| status[:id] == original.id.to_s }
    quoted_json = parsed[:referenced_statuses].find { |status| status[:id] == quoted.id.to_s }

    expect(counts[:software]).to eq(1)
    expect(referenced[:quote]).to eq(quoted.id.to_s)
    expect(referenced.dig(:tags, 0, :account_url)).to eq('https://compact-original.example/@orig/tagged/photo')
    expect(quoted_json.dig(:tags, 0, :account_url)).to eq('https://compact-quoted.example/@quot/tagged/photo')
  end

  it 'prefetches a context full of nested statuses once' do
    statuses = statuses_for('ctx', 3)
    context = Context.new(ancestors: statuses, descendants: [], references: [])
    counts = nil

    expect_one_prefetch do
      counts = capture do
        render_json(context, serializer: REST::ContextSerializer, relationships: StatusRelationshipsPresenter.new(statuses, nil))
      end
    end

    expect(counts[:software]).to eq(1)
  end

  it 'prefetches a single boost-of-a-quote once, not once per nested status' do
    quoted = tagged(remote('single-quoted.example', 'quot'), 'photo')
    original = tagged(remote('single-original.example', 'orig'), 'photo')
    node('single-quoted.example')
    node('single-original.example')
    original.update!(quote: quoted)
    boost = Fabricate(:status, account: Fabricate(:account, username: 'solo'), reblog: original)
    counts = nil

    expect_one_prefetch do
      counts = capture { render_json(boost, serializer: REST::StatusSerializer) }
    end

    expect(counts[:software]).to eq(1)
  end

  it 'renders an empty tag list as an array without account_url' do
    status = Fabricate(:status, account: Fabricate(:account, username: 'emptytags'))
    body = JSON.parse(render_json(status, serializer: REST::StatusSerializer), symbolize_names: true)

    expect(body[:tags]).to eq([])
  end
end
