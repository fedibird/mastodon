# frozen_string_literal: true

# Shadow-only calibration classifier for one cross-subject linked-negative
# overlap. This is not a risk, abuse, identity, or probability score, and it
# is not a policy cutoff. Action Review keeps receiving signal `none`.
#
# Only a cross-subject best match can raise the level. Same-subject overlap,
# action types, migration evidence, current-target ratio, jaccard, account
# age, import mode, and dispatch owner are echoed as context and ignored.
#
# Conservative containment, when the reported linked-negative count is a
# positive integer:
#
#   overlap_count / max(stored_linked_negative_target_count, reported_linked_negative_target_count)
#
# A nil stored count is treated as 0 only in that case. A missing or invalid
# reported count leaves containment unknown: medium and high are impossible,
# and low is emitted only when overlap_count >= 10.
#
# Provisional shadow thresholds, highest first:
#   high:   overlap >= 100 and containment >= 0.50
#   medium: overlap >= 25  and containment >= 0.20
#   low:    overlap >= 5   and containment >= 0.05
module FollowImport
  class ReviewSignalClassifier
    VERSION = 'follow-import-review-signal-shadow-v1'

    HIGH_OVERLAP = 100
    HIGH_CONTAINMENT = Rational(1, 2)
    MEDIUM_OVERLAP = 25
    MEDIUM_CONTAINMENT = Rational(1, 5)
    LOW_OVERLAP = 5
    LOW_CONTAINMENT = Rational(1, 20)
    UNKNOWN_COMPLETENESS_LOW_OVERLAP = 10

    REASON_NO_MATCH = 'no_cross_subject_linked_negative_overlap'
    REASON_BELOW = 'cross_subject_overlap_below_shadow_threshold'
    REASON_LOW_UNKNOWN = 'cross_subject_overlap_low_completeness_unknown'
    REASON_LOW = 'cross_subject_overlap_low'
    REASON_MEDIUM = 'cross_subject_overlap_medium'
    REASON_HIGH = 'cross_subject_overlap_high'

    # Decimal forms of the rational cutoffs above, for operators and specs.
    THRESHOLD_DECIMALS = {
      'high' => 0.50,
      'medium' => 0.20,
      'low' => 0.05,
    }.freeze

    FEATURE_KEYS = %w(
      campaign_batch_count
      target_rows
      comparable_unique_target_count
      unresolved_or_unmapped_target_rows
      cross_subject_matching_snapshot_count
      overlap_count
      current_target_overlap_ratio
      stored_negative_containment
      conservative_negative_containment
      jaccard
      historical_fingerprint_complete
      stored_linked_negative_target_count
      reported_linked_negative_target_count
      historical_action_types
      latest_historical_action_performed_at
      same_subject_matching_snapshot_count
      mode
      migration_evidence
      account_age_seconds
      dispatch_owner
    ).freeze

    THRESHOLDS = [
      ['high', HIGH_OVERLAP, HIGH_CONTAINMENT, REASON_HIGH],
      ['medium', MEDIUM_OVERLAP, MEDIUM_CONTAINMENT, REASON_MEDIUM],
      ['low', LOW_OVERLAP, LOW_CONTAINMENT, REASON_LOW],
    ].freeze

    def call(input)
      input = stringify_keys(input)
      match = input['cross_subject_best_match']
      match = nil unless match.is_a?(Hash)
      overlap = non_negative_count(match && match['overlap_count'])
      containment = conservative_containment(match, overlap)
      level, reason = classify(match, overlap, containment)
      {
        'classifier_version' => VERSION,
        'signal_level' => level,
        'reason_codes' => [reason],
        'features' => features_for(input, match, overlap, containment),
      }
    end

    private

    def classify(match, overlap, containment)
      return ['none', REASON_NO_MATCH] if match.nil?
      return unknown_completeness(overlap) if containment.nil?

      hit = THRESHOLDS.find { |_level, min_overlap, min_containment, _reason| overlap >= min_overlap && containment >= min_containment }
      return ['none', REASON_BELOW] if hit.nil?

      [hit[0], hit[3]]
    end

    def unknown_completeness(overlap)
      return ['low', REASON_LOW_UNKNOWN] if overlap && overlap >= UNKNOWN_COMPLETENESS_LOW_OVERLAP

      ['none', REASON_BELOW]
    end

    # Lower bound. Reported count is required; stored count only enlarges
    # the denominator. Never falls back to stored_negative_containment.
    def conservative_containment(match, overlap)
      return if match.nil? || overlap.nil?

      reported = positive_count(match['reported_linked_negative_target_count'])
      return if reported.nil?

      stored = non_negative_count(match['stored_linked_negative_target_count']) || 0
      Rational(overlap, [stored, reported].max)
    end

    def features_for(input, match, overlap, containment)
      source = match || {}
      {
        'campaign_batch_count' => input['campaign_batch_count'],
        'target_rows' => input['target_rows'],
        'comparable_unique_target_count' => input['comparable_unique_target_count'],
        'unresolved_or_unmapped_target_rows' => input['unresolved_or_unmapped_target_rows'],
        'cross_subject_matching_snapshot_count' => input['cross_subject_matching_snapshot_count'],
        'overlap_count' => overlap,
        'current_target_overlap_ratio' => source['current_target_overlap_ratio'],
        'stored_negative_containment' => source['stored_negative_containment'],
        'conservative_negative_containment' => containment&.to_f,
        'jaccard' => source['jaccard'],
        'historical_fingerprint_complete' => source['historical_fingerprint_complete'],
        'stored_linked_negative_target_count' => non_negative_count(source['stored_linked_negative_target_count']),
        'reported_linked_negative_target_count' => positive_count(source['reported_linked_negative_target_count']),
        'historical_action_types' => action_types(source['action_types']),
        'latest_historical_action_performed_at' => time_string(source['latest_action_performed_at']),
        'same_subject_matching_snapshot_count' => input['same_subject_matching_snapshot_count'],
        'mode' => input['mode'],
        'migration_evidence' => input['migration_evidence'],
        'account_age_seconds' => input['account_age_seconds'],
        'dispatch_owner' => input['dispatch_owner'],
      }
    end

    def action_types(value)
      Array(value).select { |item| item.is_a?(String) }
    end

    def time_string(value)
      return if value.nil?
      return value.utc.iso8601 if value.respond_to?(:utc)
      return value if value.is_a?(String)

      nil
    end

    def positive_count(value)
      count = non_negative_count(value)
      count if count&.positive?
    end

    def non_negative_count(value)
      value if value.is_a?(Integer) && value >= 0
    end

    def stringify_keys(input)
      hash = input.is_a?(Hash) ? input : {}
      hash.each_with_object({}) do |(key, value), out|
        out[key.to_s] = key.to_s == 'cross_subject_best_match' && value.is_a?(Hash) ? stringify_keys(value) : value
      end
    end
  end
end
