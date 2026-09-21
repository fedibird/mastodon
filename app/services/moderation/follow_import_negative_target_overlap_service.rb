# frozen_string_literal: true

# Analysis-only comparison of a Follow Import batch against historical linked
# negative-target fingerprints that were actually attached to a moderation
# action.
#
# Single-batch adapter around LinkedNegativeTargetOverlapComparator.
# Public behavior is unchanged from PR #141: unique non-NULL target_subject_id
# vs action-linked linked_negative_target_subject_ids, as_of defaulting to
# batch.imported_at (no look-ahead). Read-only; no score or enforcement.
module Moderation
  class FollowImportNegativeTargetOverlapService
    def initialize(comparator: Moderation::LinkedNegativeTargetOverlapComparator.new)
      @comparator = comparator
    end

    def call(batch, as_of: batch.imported_at)
      target_subject_ids = batch.targets.pluck(:target_subject_id)
      result = @comparator.call(
        subject_id: batch.subject_id,
        comparable_ids: target_subject_ids,
        as_of: as_of,
        counts: {
          target_rows: target_subject_ids.size,
          unresolved: target_subject_ids.count(&:nil?),
        }
      )

      { 'batch_id' => batch.id }.merge(result)
    end
  end
end
