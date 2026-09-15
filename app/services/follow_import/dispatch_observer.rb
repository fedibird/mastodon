# frozen_string_literal: true

# Records one FollowImport::BatchExecutionWorker pass. Never consulted to
# change claim size, reschedule delay, or whether a pass executes.
module FollowImport
  class DispatchObserver
    def self.record(batch:, observed_at:, candidate_count:, claimed_count:)
      FollowImport::Telemetry.record_dispatch(
        batch_id: batch&.id,
        observed_at: observed_at,
        candidate_count: candidate_count,
        claimed_count: claimed_count,
        pending_count: pending_count_for(batch),
        load_snapshot: FollowImport::LoadSnapshot.capture,
        execution_policy: execution_policy
      )
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('dispatch', e)
      nil
    end

    def self.pending_count_for(batch)
      return 0 if batch.nil?

      batch.targets.where(state: :pending).count
    rescue StandardError
      0
    end
    private_class_method :pending_count_for

    def self.execution_policy
      {
        'schema' => FollowImport::Telemetry::SCHEMA_NAME,
        'schema_version' => FollowImport::Telemetry::SCHEMA_VERSION,
        'execution_batch_size' => FollowImport::ExecutionPolicy.execution_batch_size,
        'execution_reschedule_in' => FollowImport::ExecutionPolicy.execution_reschedule_in.to_i,
        'gate_enforcement_enabled' => FollowImport::ExecutionPolicy.gate_enforcement_enabled?,
      }
    end
    private_class_method :execution_policy
  end
end
