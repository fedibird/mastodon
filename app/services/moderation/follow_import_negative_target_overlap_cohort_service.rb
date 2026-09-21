# frozen_string_literal: true

# Aggregates Moderation::FollowImportNegativeTargetOverlapService over a
# caller-supplied Follow Import batch cohort.
#
# This is the next analysis-only layer after single-batch overlap: an operator
# can inspect distributions of linked-negative overlap (same-subject vs
# cross-subject) before any Cross-account Recurrence score or policy is designed.
#
# Strictly observational:
#
#   * READ-ONLY — it writes nothing. It only calls the single-batch overlap
#     service, which is itself read-only.
#   * No scoring, thresholds, risk labels, recommendations, or enforcement.
#   * No population scan — the caller passes the batch relation/enumerable.
#     Repeated batch ids are de-duplicated. This service never defaults to
#     FollowImportBatch.all.
#   * No future moderation outcome labels (later suspended, etc.).
#   * same_subject vs cross_subject are descriptive id-equality categories only.
#     Cross-subject overlap is not identity proof.
#   * No-look-ahead is preserved: each batch is analyzed at batch.imported_at.
#
# A batch with no match in a category is excluded from that category's
# best-match distribution (not inserted as a zero). Top-level overlap counts
# already show non-matches.
#
# Performance: this is an offline calibration tool for small, caller-selected
# cohorts. Each unique batch invokes the single-batch overlap service, which
# currently scans eligible action-linked snapshots. elapsed_seconds is returned
# so production cost can be measured; this PR does not add snapshot indexing.
#
# Console / rails runner:
#
#   batches = FollowImportBatch.where(imported_at: 10.days.ago..Time.current).order(:imported_at)
#   result = Moderation::FollowImportNegativeTargetOverlapCohortService.new.call(batches)
#   puts JSON.pretty_generate(result)
module Moderation
  class FollowImportNegativeTargetOverlapCohortService
    CATEGORIES = %w(same_subject cross_subject).freeze
    DISTRIBUTION_METRICS = %w(
      overlap_count
      current_target_overlap_ratio
      stored_negative_containment
      jaccard
    ).freeze
    BEST_MATCH_KEYS = %w(
      snapshot_id
      historical_subject_id
      action_types
      latest_action_performed_at
      historical_fingerprint_complete
      stored_linked_negative_target_count
      reported_linked_negative_target_count
      overlap_count
      current_target_overlap_ratio
      stored_negative_containment
      jaccard
    ).freeze
    PERCENTILES = [10, 25, 50, 75, 90, 95, 99].freeze

    def initialize(overlap_service: Moderation::FollowImportNegativeTargetOverlapService.new)
      @overlap_service = overlap_service
    end

    def call(batches, now: Time.now.utc)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rows = collect_rows(batches)

      {
        'generated_at'                       => now.iso8601,
        'batch_count'                        => rows.size,
        'subject_count'                      => rows.map { |row| row['subject_id'] }.uniq.size,
        'batches_with_any_overlap'           => rows.count { |row| row['matching_snapshot_count'].to_i.positive? },
        'batches_with_same_subject_overlap'  => category_overlap_count(rows, 'same_subject'),
        'batches_with_cross_subject_overlap' => category_overlap_count(rows, 'cross_subject'),
        'coverage'                           => coverage_from(rows),
        'distributions'                      => distributions_from(rows),
        'rows'                               => rows,
        'elapsed_seconds'                    => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at,
      }
    end

    private

    def collect_rows(batches)
      seen = Set.new
      rows = []

      batches.each do |batch|
        next unless batch.respond_to?(:id) && seen.add?(batch.id)

        result = @overlap_service.call(batch, as_of: batch.imported_at)
        rows << row_for(batch, result)
      end

      rows
    end

    def row_for(batch, result)
      matches = Array(result['matches'])
      same_subject = category_block(matches, true)
      cross_subject = category_block(matches, false)

      {
        'batch_id'                           => batch.id,
        'subject_id'                         => batch.subject_id,
        'imported_at'                        => batch.imported_at,
        'target_rows'                        => result['target_rows'],
        'comparable_unique_target_count'     => result['comparable_unique_target_count'],
        'unresolved_or_unmapped_target_rows' => result['unresolved_or_unmapped_target_rows'],
        'candidate_snapshot_count'           => result['candidate_snapshot_count'],
        'matching_snapshot_count'            => result['matching_snapshot_count'],
        'same_subject'                       => same_subject,
        'cross_subject'                      => cross_subject,
      }
    end

    def category_block(matches, same_subject)
      selected = matches.select { |match| match['same_subject'] == same_subject }
      {
        'matching_snapshot_count' => selected.size,
        'best_match'              => selected.empty? ? nil : slice_best_match(selected.first),
      }
    end

    def slice_best_match(match)
      BEST_MATCH_KEYS.index_with { |key| match[key] }
    end

    def category_overlap_count(rows, category)
      rows.count { |row| row.dig(category, 'matching_snapshot_count').to_i.positive? }
    end

    def coverage_from(rows)
      same = completeness_counts(rows, 'same_subject')
      cross = completeness_counts(rows, 'cross_subject')
      {
        'complete'      => same['complete'] + cross['complete'],
        'incomplete'    => same['incomplete'] + cross['incomplete'],
        'unknown'       => same['unknown'] + cross['unknown'],
        'same_subject'  => same,
        'cross_subject' => cross,
      }
    end

    def completeness_counts(rows, category)
      counts = { 'complete' => 0, 'incomplete' => 0, 'unknown' => 0 }

      rows.each do |row|
        match = row.dig(category, 'best_match')
        next if match.nil?

        case match['historical_fingerprint_complete']
        when true
          counts['complete'] += 1
        when false
          counts['incomplete'] += 1
        else
          counts['unknown'] += 1
        end
      end

      counts
    end

    def distributions_from(rows)
      CATEGORIES.index_with do |category|
        accumulators = DISTRIBUTION_METRICS.index_with { { values: [], excluded: 0 } }
        rows.each { |row| record_distribution(accumulators, row.dig(category, 'best_match')) }
        DISTRIBUTION_METRICS.index_with { |metric| summarize(accumulators[metric]) }
      end
    end

    def record_distribution(accumulators, match)
      if match.nil?
        DISTRIBUTION_METRICS.each { |metric| accumulators[metric][:excluded] += 1 }
        return
      end

      DISTRIBUTION_METRICS.each do |metric|
        value = match[metric]
        if value.is_a?(Numeric)
          accumulators[metric][:values] << value
        else
          accumulators[metric][:excluded] += 1
        end
      end
    end

    def summarize(accumulator)
      values = accumulator[:values]
      excluded = accumulator[:excluded]
      return empty_summary(excluded) if values.empty?

      sorted = values.sort
      {
        'n'           => sorted.size,
        'excluded_n'  => excluded,
        'nonzero'     => sorted.count { |value| value != 0 },
        'min'         => sorted.first,
        'max'         => sorted.last,
        'mean'        => sorted.sum.to_f / sorted.size,
        'percentiles' => PERCENTILES.index_with { |percent| percentile(sorted, percent) },
      }
    end

    def empty_summary(excluded = 0)
      {
        'n'           => 0,
        'excluded_n'  => excluded,
        'nonzero'     => 0,
        'min'         => nil,
        'max'         => nil,
        'mean'        => nil,
        'percentiles' => PERCENTILES.index_with { nil },
      }
    end

    # Linear-interpolated percentile over an already-sorted array (numpy-style
    # "linear" method: rank = p/100 * (n - 1)).
    def percentile(sorted, percent)
      return sorted.first.to_f if sorted.size == 1

      rank = (percent / 100.0) * (sorted.size - 1)
      lower = rank.floor
      upper = rank.ceil
      return sorted[lower].to_f if lower == upper

      weight = rank - lower
      (sorted[lower] * (1 - weight)) + (sorted[upper] * weight)
    end
  end
end
