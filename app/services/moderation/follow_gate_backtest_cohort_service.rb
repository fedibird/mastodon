# frozen_string_literal: true

# Aggregates Moderation::FollowGateBacktestService results across a caller-supplied
# cohort of subjects, so an operator can compare, say, a known-legitimate
# high-volume cohort against a known-problematic one and see how often each
# friction tier would fire and how early (attempt index / minutes in).
#
# Strictly analysis-only, mirroring the calibration services:
#
#   * Read-only — reads via the backtest service (itself read-only); writes
#     nothing.
#   * No scoring/thresholds/labels/enforcement — reports reach rates and
#     first-friction distributions only.
#   * No population scan — the caller passes the subject set (a sample or a
#     hand-labelled cohort); subjects repeated in the input are de-duplicated by id.
#
# Reach rate denominator is subjects_with_follows (only subjects that made follow
# attempts can reach a friction); subjects with no follows are excluded from the
# denominator but counted in subject_count.
module Moderation
  class FollowGateBacktestCohortService
    # Non-allow friction tiers the backtest can measure, in ladder order.
    # confirm_target is intentionally excluded: the backtest cannot recover a
    # target's historical locked state, so it never models confirm_target and
    # reporting it would read as a misleading "0 reached".
    FRICTIONS = %w(rate_limit delay moderator_review).freeze
    UNSUPPORTED_FRICTIONS = { 'confirm_target' => 'target_locked is not historically recoverable, so the backtest does not model confirm_target' }.freeze
    PERCENTILES = [50, 90, 95].freeze

    def initialize(backtest_service: Moderation::FollowGateBacktestService.new)
      @backtest_service = backtest_service
    end

    def call(subjects, max_events: Moderation::FollowGateBacktestService::DEFAULT_MAX_EVENTS)
      seen                  = Set.new
      subject_count         = 0
      subjects_with_follows = 0
      policy_versions       = Set.new
      params_digests        = Set.new

      # friction => { reached:, eligible:, censored:, index: [...], minutes: [...] }
      buckets = FRICTIONS.index_with { { reached: 0, eligible: 0, censored: 0, index: [], minutes: [] } }

      subjects.each do |subject|
        next unless subject.respond_to?(:id) && seen.add?(subject.id)

        subject_count += 1
        result = @backtest_service.call(subject, max_events: max_events)
        next if result['follow_attempts'].to_i.zero?

        subjects_with_follows += 1
        policy_versions << result['gate_policy_version'] if result['gate_policy_version']
        params_digests  << result['gate_params_digest'] if result['gate_params_digest']

        truncated      = result['truncated'] ? true : false
        first_friction = result['first_friction'] || {}

        FRICTIONS.each do |friction|
          bucket = buckets[friction]
          info   = first_friction[friction]

          if info
            # Reached before any truncation -> counts as reached and eligible.
            bucket[:reached]  += 1
            bucket[:eligible] += 1
            bucket[:index]    << info['attempt_index']
            bucket[:minutes]  << info['minutes_from_first_follow']
          elsif truncated
            # Right-censored: it might have reached this friction past the cap.
            # Exclude from the eligible denominator instead of counting a false
            # "never reached".
            bucket[:censored] += 1
          else
            # Complete run that definitively did not reach this friction.
            bucket[:eligible] += 1
          end
        end
      end

      {
        'generated_at'          => Time.now.utc.iso8601,
        'subject_count'         => subject_count,
        'subjects_with_follows' => subjects_with_follows,
        'gate_policy_version'   => policy_versions.size <= 1 ? policy_versions.first : 'mixed',
        'gate_params_digest'    => params_digests.size <= 1 ? params_digests.first : 'mixed',
        'mixed_policy'          => policy_versions.size > 1 || params_digests.size > 1,
        'max_events'            => max_events,
        'unsupported_frictions' => UNSUPPORTED_FRICTIONS,
        'frictions'             => FRICTIONS.index_with { |friction| friction_summary(buckets[friction]) },
      }
    end

    private

    def friction_summary(bucket)
      {
        'subjects_reached'          => bucket[:reached],
        'subjects_eligible'         => bucket[:eligible],
        'subjects_censored'         => bucket[:censored],
        'reach_rate'                => ratio(bucket[:reached], bucket[:eligible]),
        'first_attempt_index'       => distribution(bucket[:index]),
        'first_minutes_from_follow' => distribution(bucket[:minutes]),
      }
    end

    def distribution(values)
      compact = values.compact
      return { 'n' => 0, 'min' => nil, 'max' => nil, 'mean' => nil, 'percentiles' => PERCENTILES.index_with { nil } } if compact.empty?

      sorted = compact.sort
      {
        'n'           => sorted.size,
        'min'         => sorted.first,
        'max'         => sorted.last,
        'mean'        => sorted.sum.to_f / sorted.size,
        'percentiles' => PERCENTILES.index_with { |p| percentile(sorted, p) },
      }
    end

    def percentile(sorted, percent)
      return sorted.first.to_f if sorted.size == 1

      rank  = (percent / 100.0) * (sorted.size - 1)
      lower = rank.floor
      upper = rank.ceil
      return sorted[lower].to_f if lower == upper

      weight = rank - lower
      (sorted[lower] * (1 - weight)) + (sorted[upper] * weight)
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.nil? || denominator.zero?

      numerator.to_f / denominator
    end
  end
end
