# frozen_string_literal: true

module FeedDeliveryReasonRollout
  module_function

  def compare_command(argv)
    options = { min_jobs: 1, min_compared: 1, min_coverage: {} }
    OptionParser.new do |parser|
      parser.on('--before PATH') { |value| options[:before] = value }
      parser.on('--after PATH') { |value| options[:after] = value }
      parser.on('--out PATH') { |value| options[:out] = value }
      parser.on('--min-jobs N', Integer) { |value| options[:min_jobs] = value }
      parser.on('--min-compared N', Integer) { |value| options[:min_compared] = value }
      parser.on('--min-coverage NAME=N') { |value| parse_min_coverage!(value, options[:min_coverage]) }
      parser.on('--strict') { options[:strict] = true }
    end.parse!(argv)
    raise Error, 'unexpected arguments' unless argv.empty?
    raise Error, '--before and --after are required' if options.values_at(:before, :after).any? { |value| value.to_s.empty? }
    raise Error, '--min-jobs and --min-compared must be >= 1' if options[:min_jobs] < 1 || options[:min_compared] < 1

    before = JSON.parse(File.read(options[:before]))
    after = JSON.parse(File.read(options[:after]))
    result = compare(before, after, min_jobs: options[:min_jobs], min_compared: options[:min_compared], min_coverage: options[:min_coverage])
    write_new_json(options[:out], result) if options[:out]
    print_compare(result)
    options[:strict] && result['gate']['status'] != 'REVIEW_REQUIRED' ? 3 : 0
  end

  def compare(before, after, min_jobs: 1, min_compared: 1, min_coverage: {})
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
    summary = summary_for(delta.sort.to_h)
    coverage = coverage_counts(summary)
    {
      'schema' => SCHEMA,
      'phase' => before['phase'],
      'started_at' => before['captured_at'],
      'ended_at' => after['captured_at'],
      'duration_seconds' => (end_time - start_time).round(3),
      'delta' => delta.sort.to_h,
      'summary' => summary,
      'coverage' => coverage,
      'gate' => gate(before['phase'], summary, min_jobs: min_jobs, min_compared: min_compared, min_coverage: min_coverage),
    }
  end

  def summary_for(delta)
    get = ->(field) { delta.fetch(field, 0) }
    {
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
  end

  def coverage_counts(summary)
    {
      'reply_compared' => summary['reply_agree'] + summary['reply_disagree'],
      'ignore_block_compared' => summary['ignore_block_agree'] + summary['ignore_block_disagree'],
      'list_compared' => summary['list_agree'] + summary['list_disagree'],
      'reply_evidence' => summary['reply_evidence'],
      'ignore_block_evidence' => summary['ignore_block_evidence'],
      'list_reuse' => summary['list_reuse'],
    }
  end

  def gate(phase, summary, min_jobs:, min_compared:, min_coverage: {})
    reasons = []
    reasons << 'keyword reply comparison disagreed with legacy' if summary['reply_disagree'].positive?
    reasons << 'ignore_block comparison disagreed with legacy' if summary['ignore_block_disagree'].positive?
    reasons << 'list check comparison disagreed' if summary['list_disagree'].positive?
    if summary['persist_failures'].positive? || summary['recovery_attempts'].positive?
      reasons << 'metrics Redis writes failed or needed forced recovery'
    end
    return { 'status' => 'BLOCKED', 'reasons' => reasons } unless reasons.empty?

    # off emits none of these counters. Scenario minima apply only when a phase can record them.
    if phase == 'off'
      return {
        'status' => 'REVIEW_REQUIRED',
        'reasons' => ['off does not emit delivery counters; use external Sidekiq/SQL/Redis baselines'],
      }
    end

    reasons << "keyword jobs < #{min_jobs}" if summary['keyword_jobs'] < min_jobs
    compared = summary['reply_agree'] + summary['reply_disagree']
    reasons << "reply comparison samples < #{min_compared}" if phase == 'shadow' && compared < min_compared
    coverage_counts(summary).each do |name, observed|
      minimum = min_coverage[name]
      reasons << "#{name} < #{minimum} (observed #{observed})" if minimum && observed < minimum
    end
    return { 'status' => 'INSUFFICIENT', 'reasons' => reasons } unless reasons.empty?

    {
      'status' => 'REVIEW_REQUIRED',
      'reasons' => ['counters alone do not prove parity or performance gains; run manual/SQL/Sidekiq verification'],
    }
  end

  def parse_min_coverage!(value, into)
    name, raw = value.split('=', 2)
    unless COVERAGE_NAMES.include?(name) && raw&.match?(/\A[1-9][0-9]*\z/)
      raise Error, "--min-coverage expects one of #{COVERAGE_NAMES.join(', ')}=N (N >= 1)"
    end

    into[name] = Integer(raw, 10)
  end

  def print_compare(result)
    summary = result.fetch('summary')
    coverage = result.fetch('coverage')
    puts "Phase=#{result['phase']} window=#{result['started_at']} .. #{result['ended_at']}"
    puts "Duration: #{result['duration_seconds']}s"
    puts "keyword_jobs=#{summary['keyword_jobs']} reply_agree=#{summary['reply_agree']}"
    puts "reply_disagree=#{summary['reply_disagree']} reply_fallback=#{summary['reply_fallback']}"
    puts evidence_share('reply', summary['reply_evidence'], summary['reply_fallback'])
    puts "ignore_block_agree=#{summary['ignore_block_agree']} ignore_block_disagree=#{summary['ignore_block_disagree']}"
    puts "ignore_block_fallback=#{summary['ignore_block_fallback']}"
    puts evidence_share('ignore_block', summary['ignore_block_evidence'], summary['ignore_block_fallback'])
    puts "list_agree=#{summary['list_agree']} list_disagree=#{summary['list_disagree']}"
    puts "list_reuse=#{summary['list_reuse']} crutches_build=#{summary['crutches_build']}"
    puts "persist_failures=#{summary['persist_failures']} recovery_attempts=#{summary['recovery_attempts']}"
    puts coverage.map { |name, count| "#{name}=#{count}" }.join(' ')
    missing = coverage.select { |_name, count| count.zero? }.keys
    puts "unobserved=#{missing.empty? ? 'none' : missing.join(',')}"
    puts "NOTE: #{FLUSH_NOTE}."
    puts "GATE=#{result['gate']['status']} (never authorizes automatic enforce or merge)"
    result['gate']['reasons'].each { |reason| puts "  - #{reason}" }
  end

  def evidence_share(label, evidence, fallback)
    line = "#{label}_evidence=#{evidence} #{label}_fallback=#{fallback}"
    total = evidence + fallback
    return line if total.zero?

    share = format('%.3f', evidence.to_f / total)
    "#{line} #{label}_evidence_share=#{share} (evidence/(evidence+fallback))"
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
end
