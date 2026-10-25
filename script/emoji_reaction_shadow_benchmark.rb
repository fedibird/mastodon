# frozen_string_literal: true

# Measures the marginal cost of emoji reaction resolver shadow mode (P1a):
# extra SQL statements, p50/p95 wall time and allocations per operation, with
# the flag OFF, ON at the default sample rate, and ON at sample rate 1.
#
#   RAILS_ENV=test bundle exec rails runner script/emoji_reaction_shadow_benchmark.rb
#
# Everything runs inside a transaction that is rolled back, with Sidekiq in
# fake mode (no job runs) and WebMock denying network access. Test environment
# only. This is a measurement aid; it is not part of the application.

abort 'Run with RAILS_ENV=test' unless Rails.env.test?

require 'sidekiq/testing'
require 'webmock'
require 'fabrication'
require 'faker'
include WebMock::API # rubocop:disable Style/MixinUsage
WebMock.enable!
WebMock.disable_net_connect!

Sidekiq::Testing.fake!

ITERATIONS = Integer(ENV.fetch('ITERATIONS', 300))
FANOUT_SIZES = [3, 50, 200].freeze

def percentile(values, pct)
  sorted = values.sort
  sorted[[(sorted.size * pct / 100.0).ceil - 1, 0].max]
end

def with_env(env)
  saved = env.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
  env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  yield
ensure
  saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
end

def measure(iterations)
  sql = 0
  callback = lambda do |*, payload|
    statement = payload[:sql].to_s
    sql += 1 unless payload[:name] == 'SCHEMA' || statement.match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)
  end

  times = []
  allocations = []

  ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
    iterations.times do |i|
      GC.start if (i % 50).zero?
      before = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield i
      times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
      allocations << GC.stat(:total_allocated_objects) - before
    end
  end

  { sql_per_op: sql.to_f / iterations, p50_ms: percentile(times, 50), p95_ms: percentile(times, 95), allocs_per_op: allocations.sum / iterations }
end

MODES = {
  'off' => { 'EMOJI_REACTION_RESOLVER_SHADOW' => nil, 'EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE' => nil },
  'on, default rate (0.01)' => { 'EMOJI_REACTION_RESOLVER_SHADOW' => 'true', 'EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE' => nil },
  'on, rate 1.0' => { 'EMOJI_REACTION_RESOLVER_SHADOW' => 'true', 'EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE' => '1' },
}.freeze

def table(title, rows)
  puts "\n#{title}"
  puts '| mode | extra SQL/op | SQL/op | p50 ms | p95 ms | allocations/op |'
  puts '|---|---|---|---|---|---|'
  baseline = rows.first.last[:sql_per_op]
  rows.each do |mode, r|
    puts format('| %s | %+.2f | %.2f | %.2f | %.2f | %d |', mode, r[:sql_per_op] - baseline, r[:sql_per_op], r[:p50_ms], r[:p95_ms], r[:allocs_per_op])
  end
end

def fabricate_remote(username, domain)
  Fabricate(:account, username: username, domain: domain, protocol: :activitypub, inbox_url: "https://#{domain}/inbox", uri: "https://#{domain}/users/#{username}")
end

ActiveRecord::Base.transaction do
  reactor = Fabricate(:account, username: 'bench_reactor')
  author = fabricate_remote('bench_author', 'bench-remote.example')
  Node.create!(domain: 'bench-remote.example', info: { 'emoji_reaction_type' => 'custom', 'favourite' => true }, nodeinfo: { 'software' => { 'name' => 'x' }, 'padding' => 'x' * 20_000 }, last_fetched_at: Time.now.utc)
  statuses = Array.new(ITERATIONS) { |i| Fabricate(:status, account: author, uri: "https://bench-remote.example/s/#{i}") }

  create_rows = []
  undo_rows = []

  MODES.each do |mode, env|
    EmojiReaction.where(account: reactor).delete_all
    # Fresh objects per mode so no association (author.node) is cached across modes.
    fresh = Status.includes(:account).where(id: statuses.map(&:id)).index_by(&:id).values_at(*statuses.map(&:id))
    with_env(env) do
      EmojiReactionService.new.call(reactor, fresh.first, '👍')
      UnEmojiReactionService.new.call(reactor, fresh.first, '👍', shortcode_only: true)
      create_rows << [mode, measure(ITERATIONS) { |i| EmojiReactionService.new.call(reactor, fresh[i], '👍') }]
      undo_rows << [mode, measure(ITERATIONS) { |i| UnEmojiReactionService.new.call(reactor, fresh[i], '👍', shortcode_only: true) }]
    end
    ActivityPub::DeliveryWorker.jobs.clear
  end

  table("EmojiReactionService#call, remote author, #{ITERATIONS} operations", create_rows)
  table("UnEmojiReactionService#call, remote author, #{ITERATIONS} operations", undo_rows)

  local_author = Fabricate(:account, username: 'bench_local_author')
  local_status = Fabricate(:status, account: local_author, visibility: :public)
  followers = []

  FANOUT_SIZES.each do |size|
    (size - followers.size).times do |i|
      index = followers.size + i
      domain = "bench-fan#{index}.example"
      follower = fabricate_remote("bench_fan#{index}", domain)
      Follow.create!(account: follower, target_account: reactor)
      Node.create!(domain: domain, info: { 'emoji_reaction_type' => %w(custom unicode none)[index % 3] }, nodeinfo: { 'a' => 1 }, last_fetched_at: Time.now.utc)
      followers << follower
    end

    EmojiReaction.where(account: reactor).delete_all
    reaction = EmojiReaction.create!(account: reactor, status: local_status, name: '👍')
    rows = MODES.map do |mode, env|
      with_env(env) do
        ActivityPub::CustomEmojiDistributionWorker.new.perform(reaction.id, 'create')
        [mode, measure([ITERATIONS, 100].min) { ActivityPub::CustomEmojiDistributionWorker.new.perform(reaction.id, 'create') }]
      end
    end
    ActivityPub::DeliveryWorker.jobs.clear
    table("CustomEmojiDistributionWorker#perform, #{size} follower receivers (sample limit #{EmojiReactionCapability::ShadowConfig::FANOUT_RECEIVER_SAMPLE})", rows)
  end

  raise ActiveRecord::Rollback
end

RedisConfiguration.with do |conn|
  conn.scan_each(match: "#{EmojiReactionCapability::ShadowRecorder::KEY_PREFIX}:*") { |key| conn.del(key) }
end
