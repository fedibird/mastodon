# frozen_string_literal: true

# Records one FollowImport::BatchExecutionWorker pass. Never consulted to
# change claim size, reschedule delay, or whether a pass executes.
#
# +load_snapshot+ must be the pre-dispatch capture used for any local-load
# decision on this same pass. Counts that could not be measured are left
# nil; 0 means an observed empty set.
module FollowImport
  class DispatchObserver
    def self.record(batch:, observed_at:, candidate_count:, claimed_count:, load_snapshot:, batch_pending_before:, global_pending_count:, active_batch_count:, pass_error_class: nil, local_load: nil, load_deferred: nil)
      batch_pending_after = FollowImport::DispatchCounts.pending_for(batch)
      decision = local_load&.decision

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
        execution_policy: execution_policy(local_load, decision),
        pass_error_class: pass_error_class,
        local_load_enforcement_enabled: FollowImport::ExecutionPolicy.local_load_enforcement_enabled?,
        local_load_state: decision&.state,
        local_load_budget_percent: decision&.budget_percent,
        local_load_recommended_budget: decision&.recommended_budget,
        effective_execution_budget: local_load&.enabled ? local_load.effective_budget : nil,
        local_load_would_skip: decision&.would_skip,
        local_load_measurement_complete: decision&.measurement_complete,
        local_load_profile_version: decision&.profile_version,
        local_load_profile_source: decision&.profile_source,
        local_load_fallback_used: local_load&.fallback_used,
        load_deferred: load_deferred,
        local_load_decision: decision_payload(local_load, decision)
      )
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('dispatch', e)
      nil
    end

    def self.execution_policy(local_load, decision)
      {
        'schema' => FollowImport::Telemetry::SCHEMA_NAME,
        'schema_version' => FollowImport::Telemetry::SCHEMA_VERSION,
        'execution_batch_size' => FollowImport::ExecutionPolicy.execution_batch_size,
        'execution_reschedule_in' => FollowImport::ExecutionPolicy.execution_reschedule_in.to_i,
        'gate_enforcement_enabled' => FollowImport::ExecutionPolicy.gate_enforcement_enabled?,
        'load_snapshot_timing' => 'pre_dispatch',
        'local_load_enforcement_enabled' => FollowImport::ExecutionPolicy.local_load_enforcement_enabled?,
        'local_load_enforcement_configured' => local_load&.configured,
        'local_load_profile_schema_version' => FollowImport::LocalLoadProfile::SCHEMA_VERSION,
        'local_load_controller_schema_version' => FollowImport::LocalLoadGuard::SCHEMA_VERSION,
        'local_load_profile_digest' => decision&.profile_digest,
        'local_load_profile_source' => decision&.profile_source,
      }
    end
    private_class_method :execution_policy

    def self.decision_payload(local_load, decision)
      return if local_load.nil? || !local_load.enabled || decision.nil?

      {
        'reasons' => decision.reasons,
        'enforcement_configured' => local_load.configured,
        'fallback_used' => local_load.fallback_used,
        'profile_digest' => decision.profile_digest,
      }
    end
    private_class_method :decision_payload
  end
end
