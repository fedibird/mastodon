# frozen_string_literal: true

# Groups caller-supplied Follow Import batches into temporal campaigns per
# moderation subject, unions comparable resolved targets, and compares that
# union against historical action-linked linked-negative fingerprints.
#
# Motivated by production batch-level fragmentation after PR #142: closely
# spaced batches for one subject can split one campaign's recurrence across
# several best-match rows. This layer is still analysis-only.
#
# Strictly observational:
#
#   * READ-ONLY — writes nothing. Composes LinkedNegativeTargetOverlapComparator.
#   * Caller supplies the batch enumerable; never defaults to all batches.
#   * Grouping is same ModerationSubject id + consecutive imported_at gap
#     <= max_gap. Default 30 minutes is a grouping heuristic, not a risk
#     threshold or policy cutoff. max_gap is injectable and recorded.
#   * Cross-subject overlap is not identity proof. Campaign grouping is not
#     evidence of abuse.
#   * Historical baseline freezes at campaign.started_at (earliest imported_at).
#     An action performed during the campaign is not historical evidence for it.
#   * The comparable target set may include later batches in the same completed
#     campaign. That is offline campaign analysis, not look-ahead into future
#     moderation actions.
#   * No score, "high overlap" label, recommendation, gate, or enforcement.
#
# Console / rails runner:
#
#   batches = FollowImportBatch.where(imported_at: 10.days.ago..Time.current)
#   result = Moderation::FollowImportCampaignNegativeTargetOverlapService.new.call(batches, max_gap: 30.minutes)
#   puts JSON.pretty_generate(result)
module Moderation
  class FollowImportCampaignNegativeTargetOverlapService
    DEFAULT_MAX_GAP = 30.minutes
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

    def initialize(comparator: Moderation::LinkedNegativeTargetOverlapComparator.new)
      @comparator = comparator
    end

    def call(batches, max_gap: DEFAULT_MAX_GAP, now: Time.now.utc)
      started_clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      campaigns = build_campaigns(batches, max_gap)

      {
        'generated_at'                         => now.iso8601,
        'max_gap_seconds'                      => max_gap.to_f,
        'campaign_count'                       => campaigns.size,
        'subject_count'                        => campaigns.map { |row| row['subject_id'] }.uniq.size,
        'campaigns_with_any_overlap'           => campaigns.count { |row| row['matching_snapshot_count'].to_i.positive? },
        'campaigns_with_same_subject_overlap'  => category_overlap_count(campaigns, 'same_subject'),
        'campaigns_with_cross_subject_overlap' => category_overlap_count(campaigns, 'cross_subject'),
        'coverage'                             => coverage_from(campaigns),
        'distributions'                        => distributions_from(campaigns),
        'campaigns'                            => campaigns,
        'elapsed_seconds'                      => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_clock,
      }
    end

    private

    def build_campaigns(batches, max_gap)
      grouped = group_campaigns(unique_sorted_batches(batches), max_gap)
      targets_by_batch_id = target_ids_by_batch(grouped)
      grouped.each_with_index.map { |group, index| campaign_row(group, index, targets_by_batch_id) }
    end

    def unique_sorted_batches(batches)
      seen = Set.new
      selected = []

      batches.each do |batch|
        next unless batch.respond_to?(:id) && seen.add?(batch.id)

        selected << batch
      end

      selected.sort_by { |batch| [batch.subject_id, batch.imported_at, batch.id] }
    end

    def group_campaigns(sorted_batches, max_gap)
      campaigns = []
      current = nil

      sorted_batches.each do |batch|
        if current.nil? || batch.subject_id != current[:subject_id] || gap_exceeds?(current[:ended_at], batch.imported_at, max_gap)
          current = new_group(batch)
          campaigns << current
        else
          current[:batches] << batch
          current[:ended_at] = batch.imported_at
        end
      end

      campaigns
    end

    def new_group(batch)
      {
        subject_id: batch.subject_id,
        batches: [batch],
        started_at: batch.imported_at,
        ended_at: batch.imported_at,
      }
    end

    def gap_exceeds?(previous_at, current_at, max_gap)
      (current_at - previous_at) > max_gap
    end

    def target_ids_by_batch(groups)
      batch_ids = groups.flat_map { |group| group[:batches].map(&:id) }
      return {} if batch_ids.empty?

      rows = Hash.new { |hash, key| hash[key] = [] }
      FollowImportTarget.where(batch_id: batch_ids).pluck(:batch_id, :target_subject_id).each do |batch_id, target_subject_id|
        rows[batch_id] << target_subject_id
      end
      rows
    end

    def campaign_row(group, index, targets_by_batch_id)
      batches = group[:batches]
      target_subject_ids = batches.flat_map { |batch| targets_by_batch_id[batch.id] || [] }
      comparison = @comparator.call(
        subject_id: group[:subject_id],
        comparable_ids: target_subject_ids,
        as_of: group[:started_at],
        counts: {
          target_rows: target_subject_ids.size,
          unresolved: target_subject_ids.count(&:nil?),
        }
      )

      matches = Array(comparison['matches'])
      {
        'campaign_index'                     => index,
        'campaign_key'                       => "#{group[:subject_id]}:#{batches.first.id}",
        'subject_id'                         => group[:subject_id],
        'started_at'                         => group[:started_at],
        'ended_at'                           => group[:ended_at],
        'as_of'                              => group[:started_at],
        'duration_seconds'                   => (group[:ended_at] - group[:started_at]).to_f,
        'batch_count'                        => batches.size,
        'batch_ids'                          => batches.map(&:id),
        'import_ids'                         => unique_import_ids(batches),
        'modes'                              => enum_counts(batches, :mode, FollowImportBatch.modes.keys),
        'migration_evidence'                 => enum_counts(batches, :migration_evidence, FollowImportBatch.migration_evidences.keys),
        'target_rows'                        => comparison['target_rows'],
        'comparable_unique_target_count'     => comparison['comparable_unique_target_count'],
        'unresolved_or_unmapped_target_rows' => comparison['unresolved_or_unmapped_target_rows'],
        'candidate_snapshot_count'           => comparison['candidate_snapshot_count'],
        'matching_snapshot_count'            => comparison['matching_snapshot_count'],
        'same_subject'                       => category_block(matches, true),
        'cross_subject'                      => category_block(matches, false),
      }
    end

    def unique_import_ids(batches)
      seen = Set.new
      ids = []
      batches.each do |batch|
        import_id = batch.import_id
        next if import_id.nil? || !seen.add?(import_id)

        ids << import_id
      end
      ids
    end

    def enum_counts(batches, field, keys)
      counts = keys.index_with { 0 }
      batches.each do |batch|
        key = batch.public_send(field)
        counts[key] += 1 if counts.key?(key)
      end
      counts
    end

    def category_block(matches, same_subject)
      selected = matches.select { |match| match['same_subject'] == same_subject }
      {
        'matching_snapshot_count' => selected.size,
        'best_match'              => selected.empty? ? nil : BEST_MATCH_KEYS.index_with { |key| selected.first[key] },
      }
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
