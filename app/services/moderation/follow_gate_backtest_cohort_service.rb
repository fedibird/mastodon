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
    # Non-allow friction tiers, aggregated in ladder order.
    FRICTIONS = %w(rate_limit confirm_target delay moderator_review).freeze
    PERCENTILES = [50, 90, 95].freeze

    def initialize(backtest_service: Moderation::FollowGateBacktestService.new)
      @backtest_service = backtest_service
    end

    def call(subjects, max_events: Moderation::FollowGateBacktestService::DEFAULT_MAX_EVENTS)
      seen                  = Set.new
      subject_count         = 0
      subjects_with_follows = 0
      policy_version        = nil
      params_digest         = nil

      # friction => { index: [...], minutes: [...], subjects: n }
      reached = FRICTIONS.index_with { { index: [], minutes: [], subjects: 0 } }

      subjects.each do |subject|
        next unless subject.respond_to?(:id) && seen.add?(subject.id)

        subject_count += 1
        result = @backtest_service.call(subject, max_events: max_events)
        next if result['follow_attempts'].to_i.zero?

        subjects_with_follows += 1
        policy_version ||= result['gate_policy_version']
        params_digest  ||= result['gate_params_digest']

        (result['first_friction'] || {}).each do |friction, info|
          bucket = reached[friction]
          next if bucket.nil?

          bucket[:subjects] += 1
          bucket[:index]   << info['attempt_index']
          bucket[:minutes] << info['minutes_from_first_follow']
        end
      end

      {
        'generated_at'          => Time.now.utc.iso8601,
        'subject_count'         => subject_count,
        'subjects_with_follows' => subjects_with_follows,
        'gate_policy_version'   => policy_version,
        'gate_params_digest'    => params_digest,
        'max_events'            => max_events,
        'frictions'             => FRICTIONS.index_with { |friction| friction_summary(reached[friction], subjects_with_follows) },
      }
    end

    private

    def friction_summary(bucket, denominator)
      {
        'subjects_reached'          => bucket[:subjects],
        'reach_rate'                => ratio(bucket[:subjects], denominator),
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
