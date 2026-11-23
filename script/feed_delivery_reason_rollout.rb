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
  # A 72 hour interval still touches 73 UTC hour keys: the starting hour and
  # the hour 72 hours later. Snapshots must be able to read both.
  MAX_SNAPSHOT_HOURS = MAX_HOURS + 1
  APP_ROOT = File.expand_path('..', __dir__)
  FLUSH_NOTE = 'counters can lag by one metrics flush (about 5 seconds) at each edge of the window'
  COVERAGE_NAMES = %w(
    reply_compared
    ignore_block_compared
    list_compared
    reply_evidence
    ignore_block_evidence
    list_reuse
  ).freeze

  class Error < StandardError; end

  module_function

  def run(argv)
    command = argv.shift
    case command
    when 'snapshot'      then snapshot_command(argv)
    when 'compare'       then compare_command(argv)
    when 'process-modes' then process_modes_command(argv)
    when 'check-pids'    then check_pids_command(argv)
    when 'pg-baseline'   then pg_baseline_command(argv)
    else
      raise Error, 'usage: script/feed_delivery_reason_rollout.rb snapshot|compare|process-modes|check-pids|pg-baseline [options]'
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
    raise Error, "--hours must be 1..#{MAX_SNAPSHOT_HOURS}" unless (1..MAX_SNAPSHOT_HOURS).cover?(options[:hours])

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

  def write_new_file(path, body)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(body)
    end
  rescue Errno::EEXIST
    raise Error, "output already exists (will not overwrite): #{path}"
  end

  def write_new_json(path, document)
    write_new_file(path, "#{JSON.pretty_generate(document)}\n")
  end
end

require_relative 'feed_delivery_reason_rollout/compare'
require_relative 'feed_delivery_reason_rollout/process_modes'
require_relative 'feed_delivery_reason_rollout/pg_baseline'

exit FeedDeliveryReasonRollout.run(ARGV) if $PROGRAM_NAME == __FILE__
