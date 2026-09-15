# frozen_string_literal: true

# Read-only source of pending Follow Import work for shadow planning.
#
# PR B observes the current pending universe (no dispatch_owner yet).
# PR C can pass a narrower +batch_scope+ (scheduler-owned batches) without
# rewriting FairScheduler.
#
# Discovery uses the pending-only partial index. Batches preload
# subject/account so owner resolution is not N+1. Targets are not loaded
# here; each batch gets a bounded PendingTargetFeed.
module FollowImport
  class PendingBatchSource
    def initialize(batch_scope: FollowImportBatch.all)
      @batch_scope = batch_scope
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
            feed: FollowImport::PendingTargetFeed.new(batch.id, after_position: after),
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
