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

  it 'follows an unloaded reblog of a quote in one statuses query and skips duplicates' do
    deep = remote('deep.example', 'deep')
    middle_account = remote('middle.example', 'mid')
    deep_status = Fabricate(:status, account: deep)
    middle = Fabricate(:status, account: middle_account, reblog: deep_status)
    first = Fabricate(:status, account: Fabricate(:account, username: 'one'), quote: middle)
    second = Fabricate(:status, account: Fabricate(:account, username: 'two'), quote: middle)
    unloaded = [Status.find(first.id), Status.find(second.id)]

    status_queries = queries_matching('WITH RECURSIVE nest') do
      pages = described_class.prefetch(unloaded)
      expect(pages.url_for(deep, Tag.find_or_create_by!(name: 'rails'))).to be_nil
    end

    Node.create!(domain: 'deep.example', nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)
    Node.create!(domain: 'middle.example', nodeinfo: { 'software' => { 'name' => 'mastodon', 'version' => '4.2.1' } }, last_fetched_at: Time.now.utc)
    pages = described_class.prefetch(unloaded)

    expect(status_queries.size).to eq(1)
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
end
