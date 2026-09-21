# frozen_string_literal: true

# Read-only Follow Import backlog counts. Measurement failures return nil
# (unavailable), never 0. 0 is reserved for an observed empty set.
#
# Global queries filter only `state = pending`. They use the partial index
# `index_follow_import_targets_on_pending_batch_id` so historical terminal
# rows do not have to be scanned as the target table grows.
#
# Cohort splits join the small set of currently-pending batch ids onto
# `follow_import_batches.dispatch_cohort`. They do not load targets or
# classify history from dates / target-state heuristics.
module FollowImport
  class DispatchCounts
    BacklogSnapshot = Struct.new(
      :global_pending_count,
      :active_batch_count,
      :historical_pending_count,
      :operational_pending_count,
      :planning_pending_count,
      :historical_active_batch_count,
      :operational_active_batch_count,
      :planning_active_batch_count,
      keyword_init: true
    ) do
      def self.unmeasured
        new(
          global_pending_count: nil,
          active_batch_count: nil,
          historical_pending_count: nil,
          operational_pending_count: nil,
          planning_pending_count: nil,
          historical_active_batch_count: nil,
          operational_active_batch_count: nil,
          planning_active_batch_count: nil
        )
      end
    end

    class << self
      def pending_for(batch)
        return if batch.nil?

        batch.targets.where(state: :pending).count
      rescue StandardError => e
        FollowImport::Telemetry.warn_failure('dispatch_count', e)
        nil
      end

      def global_pending
        FollowImportTarget.where(state: :pending).count
      rescue StandardError => e
        FollowImport::Telemetry.warn_failure('dispatch_count', e)
        nil
      end

      # Distinct batches that currently have at least one pending (claimable)
      # target. Does not load account/subject identifiers.
      def active_batches
        FollowImportTarget.where(state: :pending).distinct.count(:batch_id)
      rescue StandardError => e
        FollowImport::Telemetry.warn_failure('dispatch_count', e)
        nil
      end

      # One tick's backlog universes. `global_*` stay all-pending for
      # continuity. `historical_*` / `operational_*` split by durable
      # cohort (operational includes screening / review_required /
      # stopped). `planning_*` is the exact batch_scope this tick will
      # (or would) walk — SHADOW/GLOBAL scopes are ready-only, so
      # non-ready pending is provenance, not executable work. Failures
      # on a group become NULL for that group only; an observed empty
      # group is 0.
      def backlog_snapshot(planning_scope:)
        historical = scoped_pending_snapshot(FollowImportBatch.historical_cohort)
        operational = scoped_pending_snapshot(FollowImportBatch.operational_cohort)
        planning = scoped_pending_snapshot(planning_scope)

        BacklogSnapshot.new(
          global_pending_count: global_pending,
          active_batch_count: active_batches,
          historical_pending_count: historical && historical[:pending],
          operational_pending_count: operational && operational[:pending],
          planning_pending_count: planning && planning[:pending],
          historical_active_batch_count: historical && historical[:active],
          operational_active_batch_count: operational && operational[:active],
          planning_active_batch_count: planning && planning[:active]
        )
      end

      private

      def scoped_pending_snapshot(batch_scope)
        pending = FollowImportTarget.where(state: :pending, batch_id: batch_scope.select(:id))
        {
          pending: pending.count,
          active: pending.distinct.count(:batch_id),
        }
      rescue StandardError => e
        FollowImport::Telemetry.warn_failure('dispatch_count', e)
        nil
      end
    end
  end
end
