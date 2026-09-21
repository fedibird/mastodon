# frozen_string_literal: true

# Historical load-envelope comparison against a candidate global budget.
# Legacy dispatch passes and scheduler ticks are never mixed.
# bucket_seconds is the synthetic tick width, not a wall-clock minute.
module FollowImport
  class PacingBacktest
    class GlobalEnvelope
      def initialize(dispatch_passes, global_budget, bucket_seconds)
        @dispatch_passes = dispatch_passes
        @global_budget = global_budget
        @bucket_seconds = bucket_seconds
      end

      def to_h
        return omitted if @global_budget.nil?
        return unavailable('dispatch-pass input was not supplied') if @dispatch_passes.nil?
        return unavailable('no claimed_count samples with usable observed_at') if @dispatch_passes.empty?
        return unavailable('dispatch-pass claimed_count column is missing') unless claimed_column?

        buckets = Hash.new(0)
        @dispatch_passes.each do |row|
          observed_at = row.observed_at
          claimed = row.int('claimed_count')
          next if observed_at.nil? || claimed.nil?

          unix = observed_at.to_i
          buckets[unix - (unix % @bucket_seconds)] += claimed
        end
        active = buckets.values.select(&:positive?)
        return unavailable('no claimed_count samples with usable observed_at') if active.empty?

        excess_buckets = active.count { |count| count > @global_budget }
        excess_sum = active.reduce(0) { |sum, count| sum + [count - @global_budget, 0].max }
        peak = active.max
        p50 = Distribution.percentile(active, 50)
        {
          'available' => true,
          'kind' => 'historical_load_envelope',
          'candidate_global_budget' => @global_budget,
          'bucket_seconds' => @bucket_seconds,
          'synthetic_tick_width_seconds' => @bucket_seconds,
          'active_buckets' => active.length,
          'claims_per_bucket' => Distribution.summary(active),
          'fraction_of_active_buckets_above_budget' => Distribution.ratio(excess_buckets, active.length),
          'sum_of_claims_above_budget' => excess_sum,
          'candidate_budget_over_observed_p50' => Distribution.ratio(@global_budget, p50),
          'candidate_budget_over_observed_peak' => Distribution.ratio(@global_budget, peak),
          'reflow' => FollowImport::PacingBacktest::NO_REFLOW_NOTE,
          'tick_width_note' => FollowImport::PacingBacktest::SYNTHETIC_TICK_NOTE,
          'cpu_db_note' => FollowImport::PacingBacktest::CPU_DB_WARNING,
        }
      end

      private

      def claimed_column?
        @dispatch_passes.column?('claimed_count')
      rescue StandardError
        false
      end

      def omitted
        {
          'available' => false,
          'reason' => 'global_budget omitted for this scenario',
        }
      end

      def unavailable(reason)
        {
          'available' => false,
          'reason' => reason,
          'cpu_db_note' => FollowImport::PacingBacktest::CPU_DB_WARNING,
        }
      end
    end
  end
end
