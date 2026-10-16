# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Boost notification batching', type: :service do
  it 'reads only opt-in local follows in bounded batches without per-follower queries' do
    booster = Fabricate(:account)
    original = Fabricate(:status)
    boost = Fabricate(:status, account: booster, reblog: original)
    now = Time.current
    rows = 1002.times.map { |i| { username: "boost_batch_#{i}", created_at: now, updated_at: now } }
    ids = Account.insert_all!(rows, returning: %w(id)).rows.flatten
    Follow.insert_all!(ids.each_with_index.map do |id, i|
      { account_id: id, target_account_id: booster.id, notify_reblogs: i < 1001, delivery: false, created_at: now, updated_at: now }
    end)
    remote = Fabricate(:account, domain: 'remote.example')
    remote.follow!(booster, notify_reblogs: true)
    batches = []
    allow(LocalNotificationWorker).to receive(:push_bulk) { |account_ids| batches << account_ids }
    sql = []
    callback = ->(*args) { sql << args.last[:sql] if args.last[:sql].match?(/FROM "(?:follows|accounts)"/) }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      # Test the subscriber selection independently of home/list distribution.
      FanOutOnWriteService.new.send(:notify_about_reblog!, boost)
    end
    expect(batches.map(&:size)).to eq [1000, 1]
    expect(batches.flatten).to match_array(ids.first(1001))
    expect(sql.length).to eq 4
    sql = sql.select { |query| query.include?('FROM "follows"') }
    expect(sql.length).to eq 2
    expect(sql).to all(include('LIMIT', 'notify_reblogs'))
  end
end
