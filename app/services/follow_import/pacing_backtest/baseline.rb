# frozen_string_literal: true

# Aggregate observational summary of an exported transport window.
# This is not a scheduler counterfactual.
module FollowImport
  class PacingBacktest
    class Baseline
      def initialize(dataset, bucket_seconds)
        @dataset = dataset
        @bucket_seconds = bucket_seconds
      end

      def to_h
        timed = @dataset.timed_rows
        http_rows = @dataset.http_rows
        window = observation_window(timed)
        identified = timed.select { |row| row.attempt_ordinal.present? }
        firsts = identified.select(&:first_attempt?)
        {
          'dataset' => dataset_section(timed, http_rows, window),
          'first_attempts' => first_attempt_section(firsts),
          'retry_amplification' => retry_section(identified, firsts, window),
          'concentration' => {
            'destination' => concentration_for(http_rows, :destination_domain, 'd'),
            'origin' => concentration_for(http_rows, :endpoint_origin, 'o'),
          },
          'latency' => latency_section(firsts, http_rows),
          'malformed_counts' => Hash[@dataset.malformed_counts.sort],
          'missing_target_id_count' => @dataset.missing_target_id_count,
        }
      end

      private

      def dataset_section(timed, http_rows, window)
        rows = @dataset.rows
        delivery = @dataset.delivery_rows
        {
          'row_count' => rows.length,
          'usable_activitypub_delivery_rows' => delivery.length,
          'timed_delivery_execution_rows' => timed.length,
          'actual_http_request_rows' => http_rows.length,
          'rows_with_request_timestamps' => delivery.count { |row| row.request_started_at.present? },
          'rows_with_target_id' => delivery.count { |row| row.target_id.present? },
          'rows_missing_target_id' => delivery.count { |row| row.target_id.blank? },
          'min_event_time' => iso(window[:min]),
          'max_event_time' => iso(window[:max]),
          'duration_seconds' => window[:duration_seconds],
          'destination_count' => timed.map(&:destination_domain).compact.uniq.length,
          'origin_count' => timed.map(&:endpoint_origin).compact.uniq.length,
          'routing_identity_mode' => @dataset.routing_identity_mode,
          'target_identity_mode' => @dataset.routing_identity_mode,
        }
      end

      def first_attempt_section(firsts)
        {
          'unique_target_count' => firsts.length,
          'outcome_distribution' => count_by(firsts) { |row| row.outcome.presence || 'unknown' },
          'status_distribution' => count_by(firsts) { |row| row.http_status.nil? ? 'unknown' : row.http_status.to_s },
          'success_count' => firsts.count(&:success?),
          'success_rate' => Distribution.ratio(firsts.count(&:success?), firsts.length),
          'retryable_count' => firsts.count { |row| row.outcome.to_s == 'http_retryable' },
          'timeout_count' => firsts.count { |row| row.outcome.to_s == 'timeout' },
          'connection_failure_count' => firsts.count { |row| row.outcome.to_s == 'connection_failure' },
          'unknown_count' => firsts.count { |row| %w(unknown unknown_exception).include?(row.outcome.to_s) },
          'unsalvageable_count' => firsts.count { |row| row.outcome.to_s == 'http_unsalvageable' },
          'per_bucket_distribution' => Distribution.summary(bucket_counts(firsts)),
        }
      end

      def retry_section(identified, firsts, window)
        by_target = identified.group_by(&:target_id)
        attempt_counts = by_target.values.map(&:length)
        retried = by_target.select { |_id, list| list.length >= 2 }
        failed_firsts = firsts.select(&:failed?)
        later_success = failed_firsts.count { |row| later_success?(by_target[row.target_id]) }
        no_later = failed_firsts.length - later_success
        {
          'targets_with_attempts_ge_2' => retried.length,
          'total_retry_rows' => identified.count(&:retry_attempt?),
          'attempt_count_distribution' => Distribution.summary(attempt_counts),
          'max_observed_attempt_count' => attempt_counts.max,
          'later_success_observed_within_window' => later_success,
          'no_later_success_observed_within_window' => no_later,
          'observation_window_end' => iso(window[:max]),
          'right_censoring_note' => FollowImport::PacingBacktest::RIGHT_CENSOR_WARNING,
        }
      end

      def later_success?(rows)
        return false if rows.blank?

        ordered = rows.sort_by { |row| [row.event_time.to_f, row.row_number] }
        first = ordered.first
        return false if first.nil? || first.success?

        ordered.drop(1).any?(&:success?)
      end

      def concentration_for(rows, field, prefix)
        groups = Hash.new { |hash, key| hash[key] = [] }
        rows.each do |row|
          key = row.public_send(field)
          groups[key] << row
        end
        {
          'total_actual_request_attempts' => rows.length,
          'first_attempts' => rows.count(&:first_attempt?),
          'success_count' => rows.count(&:success?),
          'http_429_count' => rows.count { |row| row.http_status == 429 },
          'http_5xx_count' => rows.count { |row| row.http_status.to_i >= 500 && row.http_status.to_i < 600 },
          'timeout_count' => rows.count { |row| row.outcome.to_s == 'timeout' },
          'connection_failure_count' => rows.count { |row| row.outcome.to_s == 'connection_failure' },
          'shares' => {
            'attempts' => share_table(groups, prefix, rows.length),
            'connection_failures' => share_table(subset(groups, 'connection_failure'), prefix, rows.count { |row| row.outcome.to_s == 'connection_failure' }),
            'timeouts' => share_table(subset(groups, 'timeout'), prefix, rows.count { |row| row.outcome.to_s == 'timeout' }),
            'http_5xx' => share_table(status_subset(groups, 500...600), prefix, rows.count { |row| (500...600).cover?(row.http_status.to_i) }),
            'http_429' => share_table(status_subset(groups, 429..429), prefix, rows.count { |row| row.http_status == 429 }),
          },
        }
      end

      def subset(groups, outcome)
        filtered = {}
        groups.each do |key, list|
          hits = list.select { |row| row.outcome.to_s == outcome }
          filtered[key] = hits if hits.any?
        end
        filtered
      end

      def status_subset(groups, range)
        filtered = {}
        groups.each do |key, list|
          hits = list.select { |row| range.cover?(row.http_status.to_i) }
          filtered[key] = hits if hits.any?
        end
        filtered
      end

      def share_table(groups, prefix, total)
        ranked = groups.sort_by { |key, list| [-list.length, Privacy.label(prefix, key)] }
        counts = ranked.map { |_key, list| list.length }
        {
          'top_1_share' => top_share(counts, 1, total),
          'top_5_share' => top_share(counts, 5, total),
          'top_10_share' => top_share(counts, 10, total),
          'keys' => ranked.first(10).map do |key, list|
            {
              'label' => Privacy.label(prefix, key),
              'count' => list.length,
              'share' => Distribution.ratio(list.length, total),
            }
          end,
        }
      end

      def top_share(counts, limit, total)
        return if total.to_i <= 0

        Distribution.ratio(counts.first(limit).reduce(0, :+), total)
      end

      def latency_section(firsts, http_rows)
        http_firsts = firsts.select(&:http?)
        {
          'first_attempt_queue_wait_ms' => Distribution.summary(firsts.map(&:queue_wait_ms).compact),
          'first_attempt_request_duration_ms' => Distribution.summary(http_firsts.map(&:request_duration_ms).compact),
          'all_attempt_request_duration_ms' => Distribution.summary(http_rows.map(&:request_duration_ms).compact),
        }
      end

      def bucket_counts(rows)
        counts = Hash.new(0)
        rows.each { |row| counts[bucket_start(row.event_time)] += 1 }
        counts.values
      end

      def bucket_start(time)
        unix = time.to_i
        unix - (unix % @bucket_seconds)
      end

      def observation_window(timed)
        times = timed.map(&:event_time)
        min_at = times.min
        max_at = times.max
        duration = if min_at && max_at
                     (max_at - min_at).to_f
                   end
        { min: min_at, max: max_at, duration_seconds: duration }
      end

      def count_by(rows)
        counts = Hash.new(0)
        rows.each { |row| counts[yield(row).to_s] += 1 }
        Hash[counts.sort]
      end

      def iso(time)
        time&.utc&.iso8601(6)
      end
    end
  end
end
