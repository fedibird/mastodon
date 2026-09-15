# frozen_string_literal: true

# Read-only Follow Import backlog counts. Measurement failures return nil
# (unavailable), never 0. 0 is reserved for an observed empty set.
module FollowImport
  class DispatchCounts
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
    end
  end
end
