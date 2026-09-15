# frozen_string_literal: true

# Records one FollowImport::BatchExecutionWorker pass. Never consulted to
# change claim size, reschedule delay, or whether a pass executes.
#
# +load_snapshot+ must be the pre-dispatch capture. Counts that could not be
# measured are left nil; 0 means an observed empty set.
module FollowImport
  class DispatchObserver
    def self.record(batch:, observed_at:, candidate_count:, claimed_count:, load_snapshot:, batch_pending_before:, global_pending_count:, active_batch_count:)
      batch_pending_after = FollowImport::DispatchCounts.pending_for(batch)

      FollowImport::Telemetry.record_dispatch(
        batch_id: batch&.id,
        observed_at: observed_at,
        candidate_count: candidate_count,
        claimed_count: claimed_count,
        pending_count: batch_pending_after,
        batch_pending_before: batch_pending_before,
        batch_pending_after: batch_pending_after,
        global_pending_count: global_pending_count,
        active_batch_count: active_batch_count,
        load_snapshot: load_snapshot,
        execution_policy: execution_policy
      )
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('dispatch', e)
      nil
    end

    def self.execution_policy
      {
        'schema' => FollowImport::Telemetry::SCHEMA_NAME,
        'schema_version' => FollowImport::Telemetry::SCHEMA_VERSION,
        'execution_batch_size' => FollowImport::ExecutionPolicy.execution_batch_size,
        'execution_reschedule_in' => FollowImport::ExecutionPolicy.execution_reschedule_in.to_i,
        'gate_enforcement_enabled' => FollowImport::ExecutionPolicy.gate_enforcement_enabled?,
        'load_snapshot_timing' => 'pre_dispatch',
      }
    end
    private_class_method :execution_policy
  end
end
