# frozen_string_literal: true

# Bucket-local pressure replay against fixed destination/origin caps.
# Excess stays in the historical bucket; it is never reflowed.
#
# first_attempt is a DeliveryWorker-execution / claim-pressure proxy and
# may include a first execution that never reached HTTP.
# all_attempt is actual HTTP request pressure only.
module FollowImport
  class PacingBacktest
    class FixedPressureReplay
      def initialize(dataset, profile, bucket_seconds)
        @dataset = dataset
        @profile = profile
        @bucket_seconds = bucket_seconds
      end

      def first_attempt
        summarize(@dataset.timed_rows.select(&:first_attempt?), 'first_attempt')
      end

      def all_attempt
        summarize(@dataset.http_rows, 'all_attempt')
      end

      private

      def summarize(rows, view)
        dest_cap = @profile.destination_per_tick_cap
        origin_cap = @profile.origin_per_tick_cap
        dest_counts = Hash.new(0)
        origin_counts = Hash.new(0)
        above_dest = 0
        above_origin = 0
        above_either = 0
        successful_either = 0
        failed_either = 0

        rows.sort_by { |row| [row.event_time.to_f, row.row_number] }.each do |row|
          dest_id = Routing.destination_pressure_key(row)
          origin_id = Routing.origin_pressure_key(row)
          dest_key = bucket_key(row, dest_id)
          origin_key = bucket_key(row, origin_id)
          dest_over = dest_key && dest_counts[dest_key] + 1 > dest_cap
          origin_over = origin_key && origin_counts[origin_key] + 1 > origin_cap
          either_over = dest_over || origin_over

          above_dest += 1 if dest_over
          above_origin += 1 if origin_over
          if either_over
            above_either += 1
            if row.success?
              successful_either += 1
            else
              failed_either += 1
            end
          end

          dest_counts[dest_key] += 1 if dest_key
          origin_counts[origin_key] += 1 if origin_key
        end

        {
          'view' => view,
          'bucket_seconds' => @bucket_seconds,
          'synthetic_tick_width_seconds' => @bucket_seconds,
          'observed_attempts' => rows.length,
          'above_destination_cap' => above_dest,
          'above_origin_cap' => above_origin,
          'above_either_cap' => above_either,
          'successful_above_either_cap' => successful_either,
          'failed_above_either_cap' => failed_either,
          'note' => 'constraint exposure, not prevented successes or failures',
          'reflow' => FollowImport::PacingBacktest::NO_REFLOW_NOTE,
          'tick_width_note' => FollowImport::PacingBacktest::SYNTHETIC_TICK_NOTE,
          'origin_pressure_note' => FollowImport::PacingBacktest::ORIGIN_PRESSURE_NOTE,
        }
      end

      def bucket_key(row, identity)
        return if identity.blank?

        unix = row.event_time.to_i
        "#{unix - (unix % @bucket_seconds)}:#{identity}"
      end
    end
  end
end
