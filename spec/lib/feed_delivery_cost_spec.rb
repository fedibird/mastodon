# frozen_string_literal: true

require 'rails_helper'

# Counts SQL, allocations, and Redis flushes for 1/100/1000 destinations.
# Redis writes are the bounded assertion. The table is the measurement.
RSpec.describe 'Feed delivery reason cost' do
  SIZES = [1, 100, 1000].freeze

  around do |example|
    previous = ENV.fetch(FeedDelivery::MODE_ENV, nil)
    FeedDelivery::Metrics.reset!
    example.run
    ENV[FeedDelivery::MODE_ENV] = previous
    FeedDelivery::Metrics.reset!
  end

  def insert_accounts(prefix, count)
    now = Time.current
    rows = count.times.map { |index| { username: "#{prefix}_#{index}_#{SecureRandom.hex(3)}", created_at: now, updated_at: now } }
    Account.insert_all!(rows, returning: %w(id)).rows.flatten
  end

  def measure
    queries = 0
    allocated = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    callback = lambda do |*, payload|
      sql = payload[:sql]
      queries += 1 unless payload[:name] == 'SCHEMA' || sql.match?(/\A(?:BEGIN|COMMIT|SAVEPOINT|RELEASE)/)
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    {
      seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
      sql: queries,
      allocations: GC.stat(:total_allocated_objects) - allocated,
    }
  end

  def report(rows)
    lines = ['mode size kind seconds sql allocations redis_flushes']
    rows.each do |row|
      lines << format(
        '%s %d %s %.4f %d %d %d',
        row[:mode], row[:size], row[:kind], row[:seconds], row[:sql], row[:allocations], row[:redis]
      )
    end
    text = lines.join("\n")
    File.write('/opt/cursor/artifacts/feed-delivery-cost.log', "#{text}\n")
    warn text
  end

  it 'keeps Redis writes off the per-destination path' do
    author = Fabricate(:account, username: 'cost_author')
    status = Fabricate(:status, account: author, text: 'say alpha please', visibility: :public)
    rows = []

    SIZES.each do |size|
      ids = insert_accounts("cost#{size}", size)
      now = Time.current
      KeywordSubscribe.insert_all!(ids.map do |id|
        { account_id: id, keyword: 'alpha', name: '', exclude_keyword: '', disabled: false, created_at: now, updated_at: now }
      end)

      %w(off shadow enforce).each do |mode|
        ENV[FeedDelivery::MODE_ENV] = mode
        FeedDelivery::Metrics.reset!
        pushes = 0
        allow(FeedInsertWorker).to receive(:push_bulk) { |items, &block| items.each { |item| pushes += 1 if block.call(item) } }
        sample = measure { FanOutOnWriteService.new.call(status) }
        rows << sample.merge(mode: mode, size: size, kind: 'keyword_fanout', redis: FeedDelivery::Metrics.flush_count)
        expect(pushes).to eq size
        expect(FeedDelivery::Metrics.flush_count).to eq(mode == 'off' ? 0 : 1)
      end

      KeywordSubscribe.where(account_id: ids).delete_all
      Account.where(id: ids).delete_all
    end

    SIZES.each do |size|
      ids = insert_accounts("plain#{size}", size)
      plain = Fabricate(:status, account: author, text: "plain #{size}", visibility: :public)

      %w(off shadow).each do |mode|
        ENV[FeedDelivery::MODE_ENV] = mode
        FeedDelivery::Metrics.reset!
        sample = measure do
          ids.each { |id| FeedInsertWorker.new.perform(plain.id, id, 'home') }
        end
        rows << sample.merge(mode: mode, size: size, kind: 'plain_home', redis: FeedDelivery::Metrics.flush_count)
        expect(FeedDelivery::Metrics.flush_count).to eq 0
      end

      Account.where(id: ids).delete_all
    end

    report(rows)
  end
end
