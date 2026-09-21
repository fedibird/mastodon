# frozen_string_literal: true

# Read-only source of pending Follow Import work.
#
# Shadow ticks (GLOBAL=false) observe ready operational batches
# (legacy + scheduler owners) so live GLOBAL-off imports stay
# comparable without treating pre-I2 historical pending, or
# non-ready preflight rows, as live scheduler backlog.
# Authoritative GLOBAL ticks MUST pass
# batch_scope: FollowImportBatch.global_planning_scope
# (operational AND scheduler-owned AND ready) so a legacy-owned,
# historical, or non-ready batch can never enter the real claim
# plan. Eligibility.executable? is a second ready-only fence.
#
# Discovery uses the pending-only partial index. Batches preload
# subject/account so owner resolution is not N+1. Targets are not loaded
# here; each batch gets a bounded PendingTargetFeed.
module FollowImport
  class PendingBatchSource
    def initialize(batch_scope: FollowImportBatch.shadow_planning_scope, scan_policy: nil)
      @batch_scope = batch_scope
      @scan_policy = scan_policy
    end

    def owner_work(cursor:)
      skipped = 0
      grouped = Hash.new { |hash, key| hash[key] = [] }

      load_batches.each do |batch|
        next unless FollowImport::Eligibility.executable?(batch)

        key = FollowImport::OwnerKey.for_batch(batch)
        if key.nil?
          skipped += 1
          next
        end

        grouped[key] << batch
      end

      owners = grouped.keys.sort.map do |key|
        batches = grouped[key].sort_by(&:id).map do |batch|
          after = cursor.last_position_by_batch[batch.id.to_s]
          {
            id: batch.id,
            feed: FollowImport::PendingTargetFeed.new(
              batch.id,
              after_position: after,
              max_targets: @scan_policy&.max_targets_per_batch,
              max_windows: @scan_policy&.max_windows_per_batch
            ),
          }
        end
        { key: key.to_s, batches: batches }
      end

      [owners, skipped]
    end

    private

    def load_batches
      ids = FollowImportTarget.where(state: :pending).distinct.pluck(:batch_id)
      return [] if ids.empty?

      @batch_scope.where(id: ids).includes(subject: :account).to_a
    end
  end
end
