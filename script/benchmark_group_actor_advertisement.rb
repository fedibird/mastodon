# frozen_string_literal: true

# Read-only direct serializer benchmark for a single local staging Group.
# Usage: GROUP_USERNAME=seven_days_war ITERATIONS=40 RAILS_ENV=production \
#   bundle exec rails runner script/benchmark_group_actor_advertisement.rb
#
# This alters ENV only inside this one runner process. It neither changes
# production web workers nor publishes/updates any ActivityPub objects.
require 'json'

username = ENV.fetch('GROUP_USERNAME')
iterations = Integer(ENV.fetch('ITERATIONS', '40'), 10)
abort 'ITERATIONS must be between 10 and 200' unless (10..200).cover?(iterations)
group = Account.find_by!(username: username, domain: nil)
abort 'Expected a live local Group' unless group.local? && group.group? && !group.suspended?

advertisement = ActivityPub::GroupProtocolAdvertisement
original_emit = ENV[advertisement::EMIT_ENV]
original_ids = ENV[advertisement::ACTOR_IDS_ENV]

serialize_actor = lambda do
  JSON.parse(
    ActiveModelSerializers::SerializableResource.new(
      group,
      serializer: ActivityPub::ActorSerializer,
      adapter: ActivityPub::Adapter
    ).to_json
  )
end

percentile = lambda do |numbers, fraction|
  sorted = numbers.sort
  sorted[[(sorted.size * fraction).ceil - 1, 0].max]
end

run_mode = lambda do |enabled|
  ENV[advertisement::EMIT_ENV] = enabled ? 'true' : 'false'
  ENV[advertisement::ACTOR_IDS_ENV] = enabled ? group.id.to_s : ''

  # Warm up class, association and formatting paths outside the measurement.
  5.times { serialize_actor.call }
  GC.start

  sql_count = 0
  callback = lambda do |_name, _start, _finish, _id, payload|
    next if payload[:cached] || payload[:name] == 'SCHEMA'
    next if payload[:sql].to_s.match?(/\A(?:BEGIN|COMMIT|ROLLBACK)\b/i)

    sql_count += 1
  end

  durations_ms = []
  allocations = []
  ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
    iterations.times do
      before_alloc = GC.stat(:total_allocated_objects)
      before_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      body = serialize_actor.call

      durations_ms << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - before_time) * 1000
      allocations << GC.stat(:total_allocated_objects) - before_alloc

      expected = enabled ? [advertisement::MENTION_FOLLOW_ANNOUNCE_IRI] : nil
      actual = body['fedibirdGroupProtocols']
      abort "Unexpected #{enabled ? 'ON' : 'OFF'} output: #{actual.inspect}" unless actual == expected
    end
  end

  {
    mode: enabled ? 'ON' : 'OFF',
    iterations: iterations,
    ms_p50: percentile.call(durations_ms, 0.50).round(2),
    ms_p95: percentile.call(durations_ms, 0.95).round(2),
    allocations_per_call: (allocations.sum.to_f / iterations).round(1),
    sql_queries_total: sql_count,
  }
end

begin
  # Alternate twice to expose order/warm-up effects; the final ON is followed
  # by OFF, leaving only the prior process environment in the ensure block.
  results = [false, true, false, true].map { |enabled| run_mode.call(enabled) }
  puts "Group Account.id=#{group.id}; direct Actor serializer (not HTTP/NGINX)"
  results.each { |result| puts result.inspect }
ensure
  ENV[advertisement::EMIT_ENV] = original_emit
  ENV[advertisement::ACTOR_IDS_ENV] = original_ids
end
