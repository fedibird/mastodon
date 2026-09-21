# frozen_string_literal: true

# Analysis-only comparison of a Follow Import batch against historical linked
# negative-target fingerprints that were actually attached to a moderation
# action.
#
# This is strictly observational:
#
#   * READ-ONLY — it never writes to the database.
#   * No score, risk label, threshold, recommendation, gate, or enforcement.
#   * Current side: unique non-NULL FollowImportTarget#target_subject_id only.
#     Duplicate rows count once. Unresolved / unmapped rows are reported but
#     never enter the overlap denominator. target_key_hash is not identity.
#   * Historical side: snapshot.linked_negative_target_subject_ids only, and
#     only for snapshots linked to at least one ModerationAction whose
#     performed_at is <= as_of. Correlated-negative IDs, full historical import
#     lists, and identity inference are out of scope.
#   * as_of defaults to batch.imported_at so historical replay has no look-ahead.
#   * Fingerprint truncation is surfaced, not "corrected". An incomplete
#     stored set makes overlap a lower-bound observation.
#   * same_subject is a boolean only; two different subjects are not claimed
#     to be the same person.
#
# Linked overlap is a strong preceding-contact association, not causal proof.
# Absence of overlap is not evidence of safety.
module Moderation
  class FollowImportNegativeTargetOverlapService
    def call(batch, as_of: batch.imported_at)
      target_subject_ids = batch.targets.pluck(:target_subject_id)
      comparable_ids = normalize_subject_ids(target_subject_ids)
      snapshot_ids = eligible_snapshot_ids(as_of)
      matches = matches_for(batch, comparable_ids, snapshot_ids, as_of)

      {
        'batch_id'                           => batch.id,
        'subject_id'                         => batch.subject_id,
        'as_of'                              => as_of,
        'target_rows'                        => target_subject_ids.size,
        'comparable_unique_target_count'     => comparable_ids.size,
        'unresolved_or_unmapped_target_rows' => target_subject_ids.count(&:nil?),
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

    def matches_for(batch, comparable_ids, snapshot_ids, as_of)
      return [] if snapshot_ids.empty?

      actions_by_snapshot = eligible_actions_by_snapshot_id(snapshot_ids, as_of)
      matches = []

      ModerationEvidenceSnapshot.where(id: snapshot_ids).find_each do |snapshot|
        row = match_row(snapshot, batch, comparable_ids, actions_by_snapshot[snapshot.id] || [])
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

    def match_row(snapshot, batch, comparable_ids, eligible_actions)
      return if eligible_actions.empty?

      stored_ids = normalize_subject_ids(snapshot.linked_negative_target_subject_ids)
      overlap_ids = comparable_ids & stored_ids
      overlap_count = overlap_ids.size
      return if overlap_count.zero?

      stored_count = stored_ids.size
      reported_count = reported_linked_negative_target_count(snapshot, stored_count)
      union_count = (comparable_ids | stored_ids).size
      action_ids, action_types, latest_performed_at = action_metadata(eligible_actions)

      {
        'snapshot_id'                          => snapshot.id,
        'historical_subject_id'                => snapshot.subject_id,
        'same_subject'                         => snapshot.subject_id == batch.subject_id,
        'action_ids'                           => action_ids,
        'action_types'                         => action_types,
        'latest_action_performed_at'           => latest_performed_at,
        'stored_linked_negative_target_count'  => stored_count,
        'reported_linked_negative_target_count' => reported_count,
        'historical_fingerprint_complete'      => reported_count <= stored_count,
        'overlap_count'                        => overlap_count,
        'current_target_overlap_ratio'         => ratio(overlap_count, comparable_ids.size),
        'stored_negative_containment'          => ratio(overlap_count, stored_count),
        'jaccard'                              => ratio(overlap_count, union_count),
      }
    end

    def reported_linked_negative_target_count(snapshot, stored_count)
      raw = snapshot.summary['linked_negative_target_count']
      return stored_count if raw.nil?

      Integer(raw)
    rescue ArgumentError, TypeError
      stored_count
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

    # Raw float (no rounding) — presentation layers round for display.
    def ratio(numerator, denominator)
      return 0.0 if denominator.nil? || denominator.zero?

      numerator.to_f / denominator
    end
  end
end
