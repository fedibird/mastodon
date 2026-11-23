#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only observations for PR #710. Never modifies delivery mode or Redis keys.
# Snapshot requires the Rails environment; compare and process-modes do not.
require 'json'
require 'optparse'
require 'open3'
require 'time'

module FeedDeliveryReasonRollout
  SCHEMA = 1
  PREFIX = 'feed_delivery_reason:v1'
  MODE_ENV = 'FEED_DELIVERY_REASON_MODE'
  PHASES = %w(off shadow enforce).freeze
  MAX_HOURS = 72

  class Error < StandardError; end

  module_function

  def run(argv)
    command = argv.shift
    case command
    when 'snapshot'     then snapshot_command(argv)
    when 'compare'      then compare_command(argv)
    when 'process-modes' then process_modes_command(argv)
    else
      raise Error, 'usage: script/feed_delivery_reason_rollout.rb snapshot|compare|process-modes [options]'
    end
  rescue Error, OptionParser::ParseError, Errno::EACCES, Errno::ENOENT, JSON::ParserError => e
    warn "ERROR: #{e.message}"
    2
  end

  def snapshot_command(argv)
    options = { hours: 48 }
    OptionParser.new do |parser|
      parser.on('--phase PHASE', PHASES) { |value| options[:phase] = value }
      parser.on('--hours N', Integer) { |value| options[:hours] = value }
      parser.on('--out PATH') { |value| options[:out] = value }
    end.parse!(argv)
    raise Error, 'unexpected arguments' unless argv.empty?
    raise Error, '--phase (off|shadow|enforce) is required' unless options[:phase]
    raise Error, '--out PATH is required' if options[:out].to_s.empty?
    raise Error, "--hours must be 1..#{MAX_HOURS}" unless (1..MAX_HOURS).cover?(options[:hours])

    require_relative '../config/environment'
    unless FeedDelivery::Metrics::KEY_PREFIX == PREFIX
      raise Error, 'application metric key prefix changed; update this tool first'
    end

    now = Time.now.utc
    keys = hour_keys(now - (options[:hours] - 1) * 3600, now)
    rows = FeedDelivery::Metrics.with_redis do |redis|
      redis.pipelined do |pipe|
        keys.each { |key| pipe.hgetall(key) }
      end
    end
    raise Error, 'Redis did not return one hash per requested hour' unless rows.is_a?(Array) && rows.size == keys.size

    values = keys.each_with_index.to_h do |key, index|
      raw = rows[index]
      raise Error, "Redis response for #{key} is not a hash" unless raw.is_a?(Hash)

      [key, raw.transform_values { |value| nonnegative_integer(value) }]
    end
    data = {
      'schema' => SCHEMA,
      'prefix' => PREFIX,
      'captured_at' => now.iso8601(6),
      'phase' => options[:phase], # operator label; not an attestation of worker mode
      'runner_mode' => FeedDelivery.mode.to_s,
      'hours' => options[:hours],
      'keys' => values,
    }
    write_new_json(options[:out], data)
    puts "Saved #{options[:phase]} snapshot: #{options[:out]} (#{keys.size} known hourly keys; read-only)"
    warn "NOTE: --phase is only an operator label (runner #{MODE_ENV}=#{data['runner_mode']})."
    warn 'Verify EVERY live worker separately with process-modes; this runner does not attest their mode.'
    0
  end

  def compare_command(argv)
    options = { min_jobs: 1, min_compared: 1 }
    OptionParser.new do |parser|
      parser.on('--before PATH') { |value| options[:before] = value }
      parser.on('--after PATH') { |value| options[:after] = value }
      parser.on('--out PATH') { |value| options[:out] = value }
      parser.on('--min-jobs N', Integer) { |value| options[:min_jobs] = value }
      parser.on('--min-compared N', Integer) { |value| options[:min_compared] = value }
      parser.on('--strict') { options[:strict] = true }
    end.parse!(argv)
    raise Error, 'unexpected arguments' unless argv.empty?
    raise Error, '--before and --after are required' if options.values_at(:before, :after).any? { |value| value.to_s.empty? }
    raise Error, '--min-jobs and --min-compared must be >= 1' if options[:min_jobs] < 1 || options[:min_compared] < 1

    before = JSON.parse(File.read(options[:before]))
    after = JSON.parse(File.read(options[:after]))
    result = compare(before, after, min_jobs: options[:min_jobs], min_compared: options[:min_compared])
    write_new_json(options[:out], result) if options[:out]
    summary = result.fetch('summary')
    puts "Phase=#{result['phase']} window=#{result['started_at']} .. #{result['ended_at']}"
    puts "Duration: #{result['duration_seconds']}s"
    puts "keyword_jobs=#{summary['keyword_jobs']} reply_agree=#{summary['reply_agree']}"
    puts "reply_disagree=#{summary['reply_disagree']} reply_fallback=#{summary['reply_fallback']}"
    puts "ignore_block_agree=#{summary['ignore_block_agree']} ignore_block_disagree=#{summary['ignore_block_disagree']}"
    puts "ignore_block_fallback=#{summary['ignore_block_fallback']}"
    puts "list_agree=#{summary['list_agree']} list_disagree=#{summary['list_disagree']}"
    puts "list_reuse=#{summary['list_reuse']} crutches_build=#{summary['crutches_build']}"
    puts "persist_failures=#{summary['persist_failures']} recovery_attempts=#{summary['recovery_attempts']}"
    puts "GATE=#{result['gate']['status']} (never authorizes automatic enforce or merge)"
    result['gate']['reasons'].each { |reason| puts "  - #{reason}" }
    options[:strict] && result['gate']['status'] != 'REVIEW_REQUIRED' ? 3 : 0
  end

  def compare(before, after, min_jobs: 1, min_compared: 1)
    [before, after].each { |snapshot| validate_snapshot!(snapshot) }
    unless before['phase'] == after['phase']
      raise Error, 'snapshots belong to different phases; compare two snapshots within ONE phase'
    end
    start_time = Time.iso8601(before.fetch('captured_at')).utc
    end_time = Time.iso8601(after.fetch('captured_at')).utc
    raise Error, 'after snapshot must be newer than before snapshot' unless end_time > start_time
    raise Error, 'snapshot interval exceeds supported coverage (72 hours)' if end_time - start_time > MAX_HOURS * 3600

    # Only compare the active hours, including any UTC-hour rollover. All keys
    # must still be present in the AFTER snapshot (even when a hash was empty).
    # This prevents a short --hours window from silently producing bad deltas.
    keys = hour_keys(start_time, end_time)
    unless (keys - after['keys'].keys).empty?
      raise Error, 'after snapshot has insufficient hour coverage; take snapshots with larger --hours'
    end
    raise Error, 'before snapshot is missing its starting hour' unless before['keys'].key?(keys.first)

    delta = Hash.new(0)
    keys.each do |key|
      old = before['keys'].fetch(key, {})
      new_values = after['keys'].fetch(key)
      (old.keys | new_values.keys).each do |field|
        difference = new_values.fetch(field, 0) - old.fetch(field, 0)
        if difference.negative?
          raise Error, "negative counter #{field} in #{key}; Redis reset/expiry or mixed snapshots"
        end

        delta[field] += difference
      end
    end
    delta = delta.sort.to_h
    get = ->(field) { delta.fetch(field, 0) }
    summary = {
      'keyword_jobs' => get.call('job|reason=keyword'),
      'reply_agree' => get.call('kw|qual=reply|result=agree'),
      'reply_disagree' => get.call('kw|qual=reply|result=disagree'),
      'reply_fallback' => get.call('kw|qual=reply|result=fallback'),
      'reply_evidence' => get.call('kw|qual=reply|result=evidence'),
      'ignore_block_agree' => get.call('kw|qual=ignore_block|result=agree'),
      'ignore_block_disagree' => get.call('kw|qual=ignore_block|result=disagree'),
      'ignore_block_fallback' => get.call('kw|qual=ignore_block|result=fallback'),
      'ignore_block_evidence' => get.call('kw|qual=ignore_block|result=evidence'),
      'list_agree' => get.call('list|result=agree'),
      'list_disagree' => get.call('list|result=disagree'),
      'list_reuse' => get.call('list|result=reuse'),
      'crutches_build' => get.call('crutches|event=build'),
      'persist_failures' => get.call('meta|result=persist_failure'),
      'recovery_attempts' => get.call('meta|result=recovery_attempt'),
    }
    {
      'schema' => SCHEMA,
      'phase' => before['phase'],
      'started_at' => before['captured_at'],
      'ended_at' => after['captured_at'],
      'duration_seconds' => (end_time - start_time).round(3),
      'delta' => delta,
      'summary' => summary,
      'gate' => gate(before['phase'], summary, min_jobs: min_jobs, min_compared: min_compared),
    }
  end

  def gate(phase, summary, min_jobs:, min_compared:)
    reasons = []
    reasons << 'keyword reply comparison disagreed with legacy' if summary['reply_disagree'].positive?
    reasons << 'ignore_block comparison disagreed with legacy' if summary['ignore_block_disagree'].positive?
    reasons << 'list check comparison disagreed' if summary['list_disagree'].positive?
    if summary['persist_failures'].positive? || summary['recovery_attempts'].positive?
      reasons << 'metrics Redis writes failed or needed forced recovery'
    end
    return { 'status' => 'BLOCKED', 'reasons' => reasons } unless reasons.empty?

    if phase == 'off'
      return {
        'status' => 'REVIEW_REQUIRED',
        'reasons' => ['off does not emit delivery counters; use external Sidekiq/SQL/Redis baselines'],
      }
    end

    reasons << "keyword jobs < #{min_jobs}" if summary['keyword_jobs'] < min_jobs
    compared = summary['reply_agree'] + summary['reply_disagree']
    reasons << "reply comparison samples < #{min_compared}" if phase == 'shadow' && compared < min_compared
    return { 'status' => 'INSUFFICIENT', 'reasons' => reasons } unless reasons.empty?

    {
      'status' => 'REVIEW_REQUIRED',
      'reasons' => ['counters alone do not prove parity or performance gains; run manual/SQL/Sidekiq verification'],
    }
  end

  def validate_snapshot!(data)
    unless data.is_a?(Hash) && data['schema'] == SCHEMA && data['prefix'] == PREFIX
      raise Error, 'invalid snapshot schema or Redis prefix'
    end
    raise Error, 'invalid snapshot phase' unless PHASES.include?(data['phase'])
    raise Error, 'invalid captured_at' unless data['captured_at'].is_a?(String) && Time.iso8601(data['captured_at'])
    raise Error, 'snapshot keys must be a hash' unless data['keys'].is_a?(Hash)

    data['keys'].each do |key, fields|
      raise Error, "invalid hour key #{key}" unless key.match?(/\Afeed_delivery_reason:v1:\d{10}\z/)
      raise Error, "invalid counters for #{key}" unless fields.is_a?(Hash)

      fields.each do |field, count|
        raise Error, "invalid counter #{field}" unless field.is_a?(String) && count.is_a?(Integer) && count >= 0
      end
    end
  rescue ArgumentError
    raise Error, 'invalid captured_at'
  end

  def hour_keys(start_time, end_time)
    first = Time.utc(start_time.utc.year, start_time.utc.month, start_time.utc.day, start_time.utc.hour)
    last = Time.utc(end_time.utc.year, end_time.utc.month, end_time.utc.day, end_time.utc.hour)
    keys = []
    while first <= last
      keys << "#{PREFIX}:#{first.strftime('%Y%m%d%H')}"
      first += 3600
    end
    keys
  end

  def nonnegative_integer(value)
    number = Integer(value, 10)
    raise Error, 'negative Redis counter' if number.negative?

    number
  rescue ArgumentError, TypeError
    raise Error, 'non-integer Redis counter'
  end

  def write_new_json(path, document)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write("#{JSON.pretty_generate(document)}\n")
    end
  rescue Errno::EEXIST
    raise Error, "output already exists (will not overwrite): #{path}"
  end

  # Linux read-only process inspection. Prints ONLY the feature flag, never any
  # other /proc/PID/environ entries (which may contain credentials).
  def process_modes_command(argv)
    options = { pids: [], units: [] }
    OptionParser.new do |parser|
      parser.on('--pid PID', Integer) { |value| options[:pids] << value }
      parser.on('--unit NAME') { |value| options[:units] << value }
      parser.on('--expect PHASE', PHASES) { |value| options[:expect] = value }
    end.parse!(argv)
    raise Error, 'unexpected arguments' unless argv.empty?
    raise Error, 'provide one or more --pid or --unit' if options[:pids].empty? && options[:units].empty?

    options[:units].each do |unit|
      raise Error, "invalid unit name: #{unit}" unless unit.match?(/\A[a-zA-Z0-9@_.-]+\z/)

      output, error, status = Open3.capture3('systemctl', 'show', '--property=MainPID', '--value', unit)
      raise Error, "systemctl could not read #{unit}: #{error.strip}" unless status.success?

      pid = Integer(output.strip, 10, exception: false)
      raise Error, "#{unit} has no running MainPID" unless pid&.positive?

      options[:pids] << pid
      puts "unit=#{unit} main_pid=#{pid} (verify additional worker units/processes separately)"
    end
    mismatch = false
    options[:pids].uniq.each do |pid|
      raise Error, "invalid PID: #{pid}" unless pid.positive?

      entry = File.binread("/proc/#{pid}/environ").split("\0").find { |item| item.start_with?("#{MODE_ENV}=") }
      raw = entry&.split('=', 2)&.last
      normalized = raw.to_s.strip.downcase
      effective = PHASES.include?(normalized) ? normalized : 'off'
      note = if raw.nil? || normalized.empty?
               ' (unset/blank)'
             elsif PHASES.include?(normalized)
               ''
             else
               ' (invalid value, normalized to off)'
             end
      puts "pid=#{pid} #{MODE_ENV}=#{effective}#{note}"
      mismatch ||= effective != options[:expect] if options[:expect]
    end
    mismatch ? 3 : 0
  end
end

exit FeedDeliveryReasonRollout.run(ARGV) if $PROGRAM_NAME == __FILE__
