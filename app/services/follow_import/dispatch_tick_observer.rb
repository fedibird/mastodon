# frozen_string_literal: true

# Records one global Follow Import dispatch-scheduler tick.
# Observation only — never consulted to claim, pause, or slow execution.
#
# scheduler_mode=shadow: claimed_count is always forced to 0.
# scheduler_mode=global: claimed_count is the actual successful enqueue
# count, including 0 and including partial progress after an enqueue
# error. planned_count stays the plan size; do not collapse a partial
# failure into a nil-count error row when a plan exists.
#
# Insert failures are swallowed and must not break the scheduler.
module FollowImport
  class DispatchTickObserver
    SCHEMA_NAME    = 'follow_import_dispatch_tick'
    SCHEMA_VERSION = 7

    def self.record(attrs)
      attrs = attrs.to_h.symbolize_keys
      plan = attrs[:plan]
      mode = (attrs[:scheduler_mode] || plan&.scheduler_mode || 'shadow').to_s
      FollowImport::Telemetry.record_dispatch_tick(
        observed_at: attrs[:observed_at],
        tick_id: attrs[:tick_id],
        scheduler_mode: mode,
        lease_acquired: attrs[:lease_acquired],
        outcome: attrs[:outcome],
        global_pending_count: plan&.global_pending_count,
        active_batch_count: plan&.active_batch_count,
        claimed_count: plan&.claimed_count,
        planned_count: plan&.planned_count,
        planned_owner_count: plan&.planned_owner_count,
        planned_batch_count: plan&.planned_batch_count,
        executable_owner_count: plan&.executable_owner_count,
        executable_batch_count: plan&.executable_batch_count,
        unique_destination_count: plan&.unique_destination_count,
        skipped_missing_owner_count: plan&.skipped_missing_owner_count,
        fairness_state_source: plan&.fairness_state_source,
        local_load_state: plan&.local_load_state,
        local_load_budget_percent: plan&.local_load_budget_percent,
        local_load_recommended_budget: plan&.local_load_recommended_budget,
        effective_shadow_plan_budget: plan&.effective_shadow_plan_budget,
        local_load_would_skip: plan&.local_load_would_skip,
        local_load_measurement_complete: plan&.local_load_measurement_complete,
        local_load_profile_version: plan&.local_load_profile_version,
        local_load_profile_source: plan&.local_load_profile_source,
        local_load_fallback_used: plan&.local_load_fallback_used,
        global_base_budget: plan&.global_base_budget,
        effective_global_budget: plan&.effective_global_budget,
        skipped_stale_count: plan&.skipped_stale_count,
        skipped_unrecoverable_count: plan&.skipped_unrecoverable_count,
        skipped_wrong_owner_count: plan&.skipped_wrong_owner_count,
        load_snapshot: attrs[:load_snapshot],
        execution_config: plan&.execution_config || execution_config,
        error_class: attrs[:error_class],
        metadata: tick_metadata(attrs[:metadata])
      )
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('dispatch_tick', e)
      nil
    end

    def self.execution_config
      {
        'schema' => SCHEMA_NAME,
        'schema_version' => SCHEMA_VERSION,
        'execution_batch_size' => FollowImport::ExecutionPolicy.execution_batch_size,
        'execution_reschedule_in' => FollowImport::ExecutionPolicy.execution_reschedule_in.to_i,
        'gate_enforcement_enabled' => FollowImport::ExecutionPolicy.gate_enforcement_enabled?,
        'dispatch_global_enabled' => FollowImport::ExecutionPolicy.dispatch_global_enabled?,
        'dispatch_shadow_enabled' => FollowImport::ExecutionPolicy.dispatch_shadow_enabled?,
        'dispatch_interval' => FollowImport::ExecutionPolicy.dispatch_interval.to_i,
        'dispatch_shadow_interval' => FollowImport::ExecutionPolicy.dispatch_interval.to_i,
        'shadow_plan_budget' => FollowImport::ExecutionPolicy.shadow_plan_budget,
        'global_dispatch_budget' => FollowImport::ExecutionPolicy.global_dispatch_budget,
        'plan_algorithm' => FollowImport::FairScheduler::ALGORITHM,
        'plan_schema_version' => FollowImport::FairScheduler::SCHEMA_VERSION,
        'local_load_shadow_enabled' => FollowImport::ExecutionPolicy.local_load_shadow_enabled?,
        'local_load_enforcement_enabled' => FollowImport::ExecutionPolicy.local_load_enforcement_enabled?,
        'local_load_profile_schema_version' => FollowImport::LocalLoadProfile::SCHEMA_VERSION,
        'local_load_controller_schema_version' => FollowImport::LocalLoadGuard::SCHEMA_VERSION,
      }
    end
    private_class_method :execution_config

    def self.tick_metadata(metadata)
      base = {
        'schema' => SCHEMA_NAME,
        'schema_version' => SCHEMA_VERSION,
      }
      extra = metadata.presence || {}
      base.merge(extra.stringify_keys)
    end
    private_class_method :tick_metadata
  end
end
