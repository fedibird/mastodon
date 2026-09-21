# frozen_string_literal: true

# Scheduler-tick cadence summary, kept separate from legacy dispatch
# passes. Missing I2 columns are unavailable, not zero.
module FollowImport
  class PacingBacktest
    class TickSummary
      def initialize(ticks)
        @ticks = ticks
      end

      def to_h
        return unavailable if @ticks.nil?

        times = @ticks.map { |row| row.time('observed_at') }.compact.sort
        gaps = []
        times.each_cons(2) { |a, b| gaps << (b - a).to_f }
        {
          'available' => true,
          'row_count' => @ticks.length,
          'min_observed_at' => times.first&.utc&.iso8601(6),
          'max_observed_at' => times.last&.utc&.iso8601(6),
          'cadence_seconds' => Distribution.summary(gaps),
          'scheduler_mode_distribution' => count_field('scheduler_mode'),
          'outcome_distribution' => count_field('outcome'),
          'planned_count' => int_summary('planned_count'),
          'claimed_count' => int_summary('claimed_count'),
          'global_base_budget' => int_summary('global_base_budget'),
          'effective_global_budget' => int_summary('effective_global_budget'),
          'global_pending_count' => int_summary('global_pending_count'),
          'historical_pending_count' => optional_int_summary('historical_pending_count'),
          'operational_pending_count' => optional_int_summary('operational_pending_count'),
          'planning_pending_count' => optional_int_summary('planning_pending_count'),
          'note' => 'Scheduler ticks are summarized separately from legacy dispatch-pass load envelopes.',
        }
      end

      private

      def unavailable
        {
          'available' => false,
          'reason' => 'scheduler tick input was not supplied',
        }
      end

      def count_field(name)
        return unavailable_field("#{name} column is missing") unless column?(name)

        counts = Hash.new(0)
        @ticks.each do |row|
          value = row[name].to_s.strip
          key = value.empty? ? 'unknown' : value
          counts[key] += 1
        end
        Hash[counts.sort]
      end

      def int_summary(name)
        return unavailable_field("#{name} column is missing") unless column?(name)

        Distribution.summary(@ticks.map { |row| row.int(name) }.compact)
      end

      def optional_int_summary(name)
        return unavailable_field("#{name} absent from this export schema") unless column?(name)

        int_summary(name)
      end

      def unavailable_field(reason)
        payload = Distribution.summary([])
        payload['reason'] = reason
        payload
      end

      def column?(name)
        return false if @ticks.empty?

        @ticks.first.values.key?(name)
      end
    end
  end
end
