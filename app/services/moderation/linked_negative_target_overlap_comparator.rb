# frozen_string_literal: true

# Read-only comparison of a caller-supplied comparable target-subject id set
# against historical linked-negative fingerprints that were actually attached
# to a moderation action.
#
# This is the reusable overlap core used by:
#
#   * FollowImportNegativeTargetOverlapService (single batch)
#   * FollowImportCampaignNegativeTargetOverlapService (temporal campaign)
#
# Semantics match PR #141 and must stay aligned:
#
#   * READ-ONLY — never writes.
#   * No score, risk label, threshold, recommendation, gate, or enforcement.
#   * Current side is the supplied comparable ids after unique Integer
#     normalization. NULL / invalid ids are skipped, not inferred via
#     target_key_hash.
#   * Historical side is snapshot.linked_negative_target_subject_ids only, and
#     only for snapshots linked to at least one ModerationAction whose
#     performed_at is <= as_of. Correlated-negative IDs are out of scope.
#   * same_subject is subject-id equality only; it is not identity proof.
#   * Missing/invalid summary['linked_negative_target_count'] leaves
#     completeness unknown (nil). Stored ID count is never substituted.
module Moderation
  class LinkedNegativeTargetOverlapComparator
    def call(subject_id:, comparable_ids:, as_of:, counts: {})
      comparable = normalize_subject_ids(comparable_ids)
      snapshot_ids = eligible_snapshot_ids(as_of)
      matches = matches_for(subject_id, comparable, snapshot_ids, as_of)

      {
        'subject_id'                         => subject_id,
        'as_of'                              => as_of,
        'target_rows'                        => counts.fetch(:target_rows, 0),
        'comparable_unique_target_count'     => comparable.size,
        'unresolved_or_unmapped_target_rows' => counts.fetch(:unresolved, 0),
        'candidate_snapshot_count'           => snapshot_ids.size,
        'matching_snapshot_count'            => matches.size,
        'matches'                            => matches,
      }
    end

    private

    def eligible_snapshot_ids(as_of)
      ModerationEvidenceSnapshot
        .joins(:moderation_actions)
        .where('moderation_actions.performed_at <= ?', as_of)
        .distinct
        .pluck(:id)
    end

    def matches_for(subject_id, comparable_ids, snapshot_ids, as_of)
      return [] if snapshot_ids.empty?

      actions_by_snapshot = eligible_actions_by_snapshot_id(snapshot_ids, as_of)
      matches = []

      ModerationEvidenceSnapshot.where(id: snapshot_ids).find_each do |snapshot|
        row = match_row(snapshot, subject_id, comparable_ids, actions_by_snapshot[snapshot.id] || [])
        matches << row if row
      end

      sort_matches(matches)
    end

    def eligible_actions_by_snapshot_id(snapshot_ids, as_of)
      ModerationAction
        .where(evidence_snapshot_id: snapshot_ids)
        .where('performed_at <= ?', as_of)
        .order(:evidence_snapshot_id, :performed_at, :id)
        .group_by(&:evidence_snapshot_id)
    end

    def match_row(snapshot, subject_id, comparable_ids, eligible_actions)
      return if eligible_actions.empty?

      stored_ids = normalize_subject_ids(snapshot.linked_negative_target_subject_ids)
      overlap_ids = comparable_ids & stored_ids
      overlap_count = overlap_ids.size
      return if overlap_count.zero?

      stored_count = stored_ids.size
      reported_count = reported_linked_negative_target_count(snapshot)
      union_count = (comparable_ids | stored_ids).size
      action_ids, action_types, latest_performed_at = action_metadata(eligible_actions)

      {
        'snapshot_id'                           => snapshot.id,
        'historical_subject_id'                 => snapshot.subject_id,
        'same_subject'                          => snapshot.subject_id == subject_id,
        'action_ids'                            => action_ids,
        'action_types'                          => action_types,
        'latest_action_performed_at'            => latest_performed_at,
        'stored_linked_negative_target_count'   => stored_count,
        'reported_linked_negative_target_count' => reported_count,
        'historical_fingerprint_complete'       => historical_fingerprint_complete(reported_count, stored_count),
        'overlap_count'                         => overlap_count,
        'current_target_overlap_ratio'          => ratio(overlap_count, comparable_ids.size),
        'stored_negative_containment'           => ratio(overlap_count, stored_count),
        'jaccard'                               => ratio(overlap_count, union_count),
      }
    end

    def reported_linked_negative_target_count(snapshot)
      raw = snapshot.summary['linked_negative_target_count']
      return if raw.nil?

      Integer(raw)
    rescue ArgumentError, TypeError
      nil
    end

    def historical_fingerprint_complete(reported_count, stored_count)
      return if reported_count.nil?

      reported_count <= stored_count
    end

    def normalize_subject_ids(values)
      ids = Set.new
      Array(values).each do |value|
        ids << Integer(value)
      rescue ArgumentError, TypeError
        next
      end
      ids
    end

    def action_metadata(eligible_actions)
      action_ids = []
      action_types = []
      latest_performed_at = nil

      eligible_actions.each do |action|
        action_ids << action.id
        action_types << action.action_type unless action_types.include?(action.action_type)
        performed_at = action.performed_at
        latest_performed_at = performed_at if latest_performed_at.nil? || performed_at > latest_performed_at
      end

      [action_ids, action_types, latest_performed_at]
    end

    def sort_matches(matches)
      matches.sort do |left, right|
        cmp = right['overlap_count'] <=> left['overlap_count']
        next cmp unless cmp.zero?

        cmp = right['stored_negative_containment'] <=> left['stored_negative_containment']
        next cmp unless cmp.zero?

        cmp = right['latest_action_performed_at'] <=> left['latest_action_performed_at']
        next cmp unless cmp.zero?

        left['snapshot_id'] <=> right['snapshot_id']
      end
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.nil? || denominator.zero?

      numerator.to_f / denominator
    end
  end
end
