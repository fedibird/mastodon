# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountTagPage::Pages do
  def remote(domain, username)
    Fabricate(:account, username: username, domain: domain, uri: "https://#{domain}/users/#{username}", url: "https://#{domain}/@#{username}")
  end

  def queries_matching(fragment)
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      queries << sql if sql.include?(fragment)
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries
  end

  it 'follows an unloaded reblog of a shared quote once per id, not once per parent' do
    deep = remote('deep.example', 'deep')
    middle_account = remote('middle.example', 'mid')
    deep_status = Fabricate(:status, account: deep)
    middle = Fabricate(:status, account: middle_account, reblog: deep_status)
    first = Fabricate(:status, account: Fabricate(:account, username: 'one'), quote: middle)
    second = Fabricate(:status, account: Fabricate(:account, username: 'two'), quote: middle)
    unloaded = [Status.find(first.id), Status.find(second.id)]

    status_queries = queries_matching('FROM "statuses"') do
      pages = described_class.prefetch(unloaded)
      expect(pages.url_for(deep, Tag.find_or_create_by!(name: 'rails'))).to be_nil
    end

    Node.create!(domain: 'deep.example', nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)
    Node.create!(domain: 'middle.example', nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)
    pages = described_class.prefetch(unloaded)

    expect(status_queries.size).to eq(2)
    expect(pages.url_for(deep, Tag.find_or_create_by!(name: 'rails'))).to eq('https://deep.example/@deep/tagged/rails')
    expect(pages.url_for(middle_account, Tag.find_or_create_by!(name: 'rails'))).to eq('https://middle.example/@mid/tagged/rails')
  end

  it 'does not query statuses when the reblog and quote are already loaded' do
    deep = remote('loaded-deep.example', 'deep')
    middle_account = remote('loaded-middle.example', 'mid')
    deep_status = Fabricate(:status, account: deep)
    middle = Fabricate(:status, account: middle_account, quote: deep_status)
    outer = Fabricate(:status, account: Fabricate(:account, username: 'outer'), reblog: middle)
    loaded = Status.includes(:account, reblog: [:account, { quote: :account }]).find(outer.id)

    status_queries = queries_matching('FROM "statuses"') do
      described_class.prefetch([loaded])
    end

    expect(status_queries).to be_empty
  end

  it 'stops on a reblog and quote cycle' do
    left_account = remote('cycle-left.example', 'left')
    right_account = remote('cycle-right.example', 'right')
    left = Fabricate(:status, account: left_account)
    right = Fabricate(:status, account: right_account)
    left.update_columns(quote_id: right.id)
    right.update_columns(reblog_of_id: left.id)

    expect { described_class.prefetch([Status.find(left.id)]) }.not_to raise_error

    Node.create!(domain: 'cycle-left.example', nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)
    Node.create!(domain: 'cycle-right.example', nodeinfo: { 'software' => { 'name' => 'fedibird', 'version' => '0.1' } }, last_fetched_at: Time.now.utc)
    pages = described_class.prefetch([Status.find(left.id)])
    tag = Tag.find_or_create_by!(name: 'rails')

    expect(pages.url_for(left_account, tag)).to eq('https://cycle-left.example/@left/tagged/rails')
    expect(pages.url_for(right_account, tag)).to eq('https://cycle-right.example/@right/tagged/rails')
  end

  it 'does not fan out a shared child and stops past the depth cap without dropping the caller' do
    stub_const('AccountTagPage::Pages::MAX_NESTED_DEPTH', 2)

    shared = remote('wide-shared.example', 'shared')
    tail = remote('wide-tail.example', 'tail')
    beyond = remote('wide-beyond.example', 'beyond')
    shared_status = Fabricate(:status, account: shared)
    tail_status = Fabricate(:status, account: tail)
    beyond_status = Fabricate(:status, account: beyond)
    beyond_status.update_columns(quote_id: nil)
    tail_status.update_columns(quote_id: beyond_status.id)
    shared_status.update_columns(reblog_of_id: tail_status.id)

    parents = Array.new(30) do |index|
      status = Fabricate(:status, account: Fabricate(:account, username: "wide#{index}"))
      status.update_columns(quote_id: shared_status.id)
      Status.find(status.id)
    end

    [shared, tail, beyond].each do |account|
      Node.create!(domain: account.domain, nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)
    end

    pages = nil
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status_queries = queries_matching('FROM "statuses"') do
      pages = described_class.prefetch(parents)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    tag = Tag.find_or_create_by!(name: 'rails')

    expect(status_queries.size).to eq(2)
    expect(status_queries.join).not_to match(/RECURSIVE/i)
    expect(elapsed).to be < 1
    expect(pages.url_for(shared, tag)).to eq('https://wide-shared.example/@shared/tagged/rails')
    expect(pages.url_for(tail, tag)).to eq('https://wide-tail.example/@tail/tagged/rails')
    expect(pages.url_for(beyond, tag)).to be_nil

    rendered = REST::StatusSerializer.new(parents.first, account_tag_pages: pages, scope: nil, scope_name: :current_user).serializable_hash
    expect(rendered[:id]).to eq(parents.first.id.to_s)

    plan_ids = Status.order(:id).limit(40).pluck(:id)
    plan_sql = Status.where(id: plan_ids).select(:id, :account_id, :reblog_of_id, :quote_id).to_sql
    ActiveRecord::Base.connection.execute('SET LOCAL enable_seqscan = off')
    plan = ActiveRecord::Base.connection.select_values("EXPLAIN #{plan_sql}").join("\n")
    expect(plan).not_to match(/Recursive/i)
    expect(plan).to match(/Index Scan|Index Only Scan|Bitmap/i)
  end

  it 'omits ids past the expansion cap and still returns the statuses it did read' do
    stub_const('AccountTagPage::Pages::MAX_NESTED_IDS', 1)

    kept = remote('cap-kept.example', 'kept')
    dropped = remote('cap-dropped.example', 'dropped')
    kept_status = Fabricate(:status, account: kept)
    dropped_status = Fabricate(:status, account: dropped)
    kept_status.update_columns(quote_id: dropped_status.id)
    parent = Fabricate(:status, account: Fabricate(:account, username: 'capparent'))
    parent.update_columns(quote_id: kept_status.id)

    Node.create!(domain: kept.domain, nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)
    Node.create!(domain: dropped.domain, nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)

    pages = described_class.prefetch([Status.find(parent.id)])
    tag = Tag.find_or_create_by!(name: 'rails')

    expect(pages.url_for(kept, tag)).to eq('https://cap-kept.example/@kept/tagged/rails')
    expect(pages.url_for(dropped, tag)).to be_nil
  end
end
