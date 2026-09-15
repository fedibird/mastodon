# frozen_string_literal: true

# Pure local-load policy. Consumes a pre-dispatch LoadSnapshot hash; it
# does not query Sidekiq, telemetry tables, accounts, or moderation.
#
# Integer recommended_budget is floor((capacity_budget * percent) / 100).
# There is no secret minimum of 1: a computed 0 means skip/defer.
# Missing required measurements yield unknown + NULL, not 0.
# Unexpected evaluation failures yield evaluation_error + NULL, not invalid.
#
# Shadow mode (PR D) leaves the plan at the base budget when the
# recommendation is unusable. Enforcement (PR E) applies an explicit
# profile fallback outside this class — the guard never invents one.
module FollowImport
  class LocalLoadGuard
    SCHEMA_VERSION = 2
    LEVEL_ORDER = %w(busy heavy overloaded).freeze

    REASON_BY_SIGNAL = {
      'default.size' => 'default_size',
      'default.latency' => 'default_latency',
      'push.size' => 'push_size',
      'push.latency' => 'push_latency',
      'pull.size' => 'pull_size',
      'pull.latency' => 'pull_latency',
      'retry_size' => 'retry_size',
    }.freeze

    def self.evaluate(snapshot:, base_budget:, profile:)
      new(snapshot: snapshot, base_budget: base_budget, profile: profile).evaluate
    end

    def initialize(snapshot:, base_budget:, profile:)
      @snapshot = snapshot
      @base_budget = base_budget.to_i
      @profile = profile
    end

    def evaluate
      return FollowImport::LocalLoadDecision.invalid(@base_budget, @profile) if @profile&.invalid?
      return FollowImport::LocalLoadDecision.unconfigured(@base_budget, @profile) unless @profile&.configured?

      missing = missing_measurements
      return FollowImport::LocalLoadDecision.unknown(@base_budget, @profile, missing) if missing.any?

      reasons = []
      strongest = nil
      LEVEL_ORDER.each do |name|
        level = @profile.level(name)
        next unless level

        crossed = crossings(level)
        next if crossed.empty?

        reasons.concat(crossed)
        strongest = level
      end

      percent = strongest ? strongest.budget_percent : 100
      capacity, capacity_reasons = capacity_budget
      reasons.concat(capacity_reasons)
      recommended = (capacity * percent) / 100

      FollowImport::LocalLoadDecision.new(
        state: strongest ? strongest.name : 'normal',
        base_budget: @base_budget,
        recommended_budget: recommended,
        budget_percent: percent,
        would_skip: recommended.zero?,
        reasons: reasons.uniq,
        measurement_complete: true,
        profile_version: @profile.version,
        profile_source: @profile.source,
        profile_digest: @profile.digest
      )
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('local_load_guard', e)
      FollowImport::LocalLoadDecision.evaluation_error(@base_budget, @profile)
    end

    private

    def crossings(level)
      reasons = []
      FollowImport::LocalLoadProfile::QUEUE_NAMES.each do |queue|
        FollowImport::LocalLoadProfile::QUEUE_FIELDS.each do |field|
          threshold = level.queues.dig(queue, field)
          next if threshold.nil?

          value = queue_metric(queue, field)
          reasons << REASON_BY_SIGNAL["#{queue}.#{field}"] if value > threshold
        end
      end
      reasons << 'retry_size' if !level.retry_size.nil? && retry_size > level.retry_size
      reasons
    end

    def capacity_budget
      candidates = [@base_budget]
      reasons = []
      capacity = @profile.capacity

      if capacity.max_tick_claims
        candidates << capacity.max_tick_claims
        reasons << 'max_tick_capacity' if capacity.max_tick_claims < @base_budget
      end
      if capacity.per_push_thread
        push_cap = capacity.per_push_thread * integer_metric('push_concurrency')
        candidates << push_cap
        reasons << 'push_capacity' if push_cap < @base_budget
      end
      if capacity.per_pull_thread
        pull_cap = capacity.per_pull_thread * integer_metric('pull_concurrency')
        candidates << pull_cap
        reasons << 'pull_capacity' if pull_cap < @base_budget
      end

      [candidates.min, reasons]
    end

    def missing_measurements
      missing = []
      required_signals.each do |signal|
        missing << (REASON_BY_SIGNAL[signal] || 'measurement_missing') if metric_missing?(signal)
      end
      if @profile.capacity.per_push_thread && concurrency_missing?('push_concurrency')
        missing << 'push_capacity'
      end
      if @profile.capacity.per_pull_thread && concurrency_missing?('pull_concurrency')
        missing << 'pull_capacity'
      end
      missing.uniq
    end

    def required_signals
      signals = []
      FollowImport::LocalLoadProfile::LEVEL_NAMES.each do |name|
        level = @profile.level(name)
        next unless level

        FollowImport::LocalLoadProfile::QUEUE_NAMES.each do |queue|
          FollowImport::LocalLoadProfile::QUEUE_FIELDS.each do |field|
            signals << "#{queue}.#{field}" if level.queues.dig(queue, field)
          end
        end
        signals << 'retry_size' unless level.retry_size.nil?
      end
      signals.uniq
    end

    def metric_missing?(signal)
      return snapshot_unusable? if @snapshot.nil?

      if signal == 'retry_size'
        return true if @snapshot['retry_size_error_class']
        return @snapshot['retry_size'].nil?
      end

      queue, field = signal.split('.')
      entry = (@snapshot['queues'] || {})[queue]
      return true if entry.nil? || entry['error_class']

      entry[field].nil?
    end

    def concurrency_missing?(key)
      return true if snapshot_unusable?
      return true if @snapshot['concurrency_error_class']

      @snapshot[key].nil?
    end

    def snapshot_unusable?
      @snapshot.nil? || @snapshot['error_class']
    end

    def queue_metric(queue, field)
      @snapshot.fetch('queues').fetch(queue).fetch(field)
    end

    def retry_size
      @snapshot.fetch('retry_size')
    end

    def integer_metric(key)
      @snapshot.fetch(key).to_i
    end
  end
end
