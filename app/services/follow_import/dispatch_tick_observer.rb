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
    SCHEMA_VERSION = 10
    BACKLOG_SCOPE_STRATEGY = 'dispatch_cohort_v1'

    def self.record(attrs) # rubocop:disable Metrics/MethodLength
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
        historical_pending_count: plan&.historical_pending_count,
        operational_pending_count: plan&.operational_pending_count,
        planning_pending_count: plan&.planning_pending_count,
        historical_active_batch_count: plan&.historical_active_batch_count,
        operational_active_batch_count: plan&.operational_active_batch_count,
        planning_active_batch_count: plan&.planning_active_batch_count,
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
        remote_admission_enabled: plan&.remote_admission_enabled,
        remote_admission_configured: plan&.remote_admission_configured,
        remote_profile_version: plan&.remote_profile_version,
        skipped_destination_cap_count: plan&.skipped_destination_cap_count,
        skipped_origin_cap_count: plan&.skipped_origin_cap_count,
        skipped_unavailable_count: plan&.skipped_unavailable_count,
        skipped_retry_after_count: plan&.skipped_retry_after_count,
        skipped_recent_429_count: plan&.skipped_recent_429_count,
        scanned_target_count: plan&.scanned_target_count,
        windows_scanned: plan&.windows_scanned,
        scan_budget_exhausted_count: plan&.scan_budget_exhausted_count,
        mapped_origin_candidate_count: plan&.mapped_origin_candidate_count,
        adaptive_remote_shadow_enabled: plan&.adaptive_remote_shadow_enabled,
        adaptive_remote_configured: plan&.adaptive_remote_configured,
        adaptive_profile_version: plan&.adaptive_profile_version,
        adaptive_shadow_evaluated_current_claim_count: plan&.adaptive_shadow_evaluated_current_claim_count,
        adaptive_shadow_would_block_current_claim_count: plan&.adaptive_shadow_would_block_current_claim_count,
        adaptive_shadow_destination_would_block_count: plan&.adaptive_shadow_destination_would_block_count,
        adaptive_shadow_origin_would_block_count: plan&.adaptive_shadow_origin_would_block_count,
        adaptive_runtime_unavailable_count: plan&.adaptive_runtime_unavailable_count,
        adaptive_destination_cap_min: plan&.adaptive_destination_cap_min,
        adaptive_destination_cap_max: plan&.adaptive_destination_cap_max,
        adaptive_origin_cap_min: plan&.adaptive_origin_cap_min,
        adaptive_origin_cap_max: plan&.adaptive_origin_cap_max,
        load_snapshot: attrs[:load_snapshot],
        execution_config: plan&.execution_config || execution_config,
        error_class: attrs[:error_class],
        metadata: tick_metadata(attrs[:metadata], plan)
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
        'lease_strategy' => FollowImport::DispatchLease::STRATEGY,
        'backlog_scope_strategy' => BACKLOG_SCOPE_STRATEGY,
        'plan_algorithm' => FollowImport::FairScheduler::ALGORITHM,
        'plan_schema_version' => FollowImport::FairScheduler::SCHEMA_VERSION,
        'local_load_shadow_enabled' => FollowImport::ExecutionPolicy.local_load_shadow_enabled?,
        'local_load_enforcement_enabled' => FollowImport::ExecutionPolicy.local_load_enforcement_enabled?,
        'local_load_profile_schema_version' => FollowImport::LocalLoadProfile::SCHEMA_VERSION,
        'local_load_controller_schema_version' => FollowImport::LocalLoadGuard::SCHEMA_VERSION,
        'remote_admission_enforcement_enabled' => FollowImport::ExecutionPolicy.remote_admission_enforcement_enabled?,
        'remote_admission_profile_schema_version' => FollowImport::RemoteAdmissionProfile::SCHEMA_VERSION,
        'adaptive_remote_shadow_enabled' => FollowImport::ExecutionPolicy.remote_adaptive_shadow_enabled?,
        'adaptive_profile_schema_version' => FollowImport::AdaptiveRemoteProfile::SCHEMA_VERSION,
      }
    end
    private_class_method :execution_config

    def self.tick_metadata(metadata, plan = nil)
      base = {
        'schema' => SCHEMA_NAME,
        'schema_version' => SCHEMA_VERSION,
      }
      extra = (metadata.presence || {}).stringify_keys
      extra['adaptive_destination_state_sources'] = plan.adaptive_destination_state_sources if plan&.adaptive_destination_state_sources.present?
      extra['adaptive_origin_state_sources'] = plan.adaptive_origin_state_sources if plan&.adaptive_origin_state_sources.present?
      base.merge(extra)
    end
    private_class_method :tick_metadata
  end
end
