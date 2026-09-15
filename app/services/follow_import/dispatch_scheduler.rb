# frozen_string_literal: true

# Global Follow Import dispatcher tick.
#
# Modes (one tick, one advisory lease, one budget, one plan):
#   GLOBAL=false, SHADOW=false -> cheap no-op
#   GLOBAL=false, SHADOW=true  -> existing shadow planner, claimed_count=0
#   GLOBAL=true                -> authoritative claim/enqueue of
#                                 scheduler-owned pending targets
#
# When both GLOBAL and SHADOW are true, GLOBAL wins for execution mode.
# The tick still records the same planning aggregates. Do not run a
# second shadow allocation.
#
# Shadow must not transition targets, enqueue RelationshipWorker, or
# finalize Imports. Global claims go through DispatchExecutor.
#
# The PostgreSQL session advisory lease (DispatchLease) remains the
# real single-flight boundary and covers snapshot, budget, planning,
# claims, enqueue, and telemetry.
module FollowImport
  class DispatchScheduler
    OUTCOME_SHADOW_DISABLED = 'shadow_disabled'
    OUTCOME_LEASE_BUSY      = 'lease_busy'
    OUTCOME_SHADOW_OBSERVED = 'shadow_observed'
    OUTCOME_SHADOW_ERROR    = 'shadow_error'
    OUTCOME_GLOBAL_OBSERVED = 'global_observed'
    OUTCOME_GLOBAL_ERROR    = 'global_error'

    Result = Struct.new(:outcome, :lease_acquired, :plan, :tick_id, keyword_init: true)

    def call
      tick_id = SecureRandom.uuid
      observed_at = Time.now.utc
      mode = FollowImport::ExecutionPolicy.dispatch_scheduler_mode

      if mode.nil?
        return Result.new(outcome: OUTCOME_SHADOW_DISABLED, lease_acquired: false, plan: nil, tick_id: tick_id)
      end

      status = FollowImport::DispatchLease.with_lease do
        run_acquired(tick_id, observed_at, mode)
      end

      return busy_result(tick_id, observed_at, mode) if status == FollowImport::DispatchLease::BUSY

      status
    rescue StandardError => e
      record_tick(
        tick_id: tick_id,
        observed_at: observed_at,
        outcome: error_outcome(mode),
        scheduler_mode: mode_name(mode),
        lease_acquired: false,
        error_class: e.class.name,
        metadata: { 'error_class' => e.class.name }
      )
      Result.new(outcome: error_outcome(mode), lease_acquired: false, plan: nil, tick_id: tick_id)
    end

    private

    def busy_result(tick_id, observed_at, mode)
      record_tick(
        tick_id: tick_id,
        observed_at: observed_at,
        outcome: OUTCOME_LEASE_BUSY,
        scheduler_mode: mode_name(mode),
        lease_acquired: false
      )
      Result.new(outcome: OUTCOME_LEASE_BUSY, lease_acquired: false, plan: nil, tick_id: tick_id)
    end

    def run_acquired(tick_id, observed_at, mode)
      load_snapshot, load_error = capture_load_snapshot
      plan = nil
      execution = nil

      plan = build_plan(observed_at, load_snapshot, mode)
      execution = execute_global(plan) if mode == :global
      plan.with_execution(execution) if plan && execution

      metadata = {}
      metadata['load_snapshot_error_class'] = load_error if load_error
      metadata['fairness_persist_failed'] = true if plan.fairness_state_source == FollowImport::FairnessCursor::SOURCE_PERSIST_FAILED
      metadata['local_load_reasons'] = plan.local_load_reasons if plan.local_load_reasons.present?
      metadata['local_load_fallback_used'] = plan.local_load_fallback_used unless plan.local_load_fallback_used.nil?
      metadata['error_class'] = execution.error_class if execution&.error_class

      outcome = if mode == :global
                  execution&.error? ? OUTCOME_GLOBAL_ERROR : OUTCOME_GLOBAL_OBSERVED
                else
                  OUTCOME_SHADOW_OBSERVED
                end

      record_tick(
        tick_id: tick_id,
        observed_at: observed_at,
        outcome: outcome,
        scheduler_mode: mode_name(mode),
        lease_acquired: true,
        plan: plan,
        load_snapshot: load_snapshot,
        error_class: execution&.error_class,
        metadata: metadata
      )

      Result.new(outcome: outcome, lease_acquired: true, plan: plan, tick_id: tick_id)
    rescue StandardError => e
      record_tick(
        tick_id: tick_id,
        observed_at: observed_at,
        outcome: error_outcome(mode),
        scheduler_mode: mode_name(mode),
        lease_acquired: true,
        plan: plan,
        error_class: e.class.name,
        metadata: { 'error_class' => e.class.name }
      )
      Result.new(outcome: error_outcome(mode), lease_acquired: true, plan: plan, tick_id: tick_id)
    end

    def execute_global(plan)
      return FollowImport::DispatchExecutor::Result.new(
        claimed_count: 0,
        skipped_stale_count: 0,
        skipped_unrecoverable_count: 0,
        skipped_wrong_owner_count: 0,
        error_class: nil,
        stopped: false
      ) if plan.nil? || !plan.planned? || plan.entries.empty?

      FollowImport::DispatchExecutor.new(now: plan.observed_at).execute(plan.entries)
    end

    def build_plan(observed_at, load_snapshot, mode)
      if mode == :global
        base_budget = FollowImport::ExecutionPolicy.global_dispatch_budget
        resolved = global_local_load(load_snapshot, base_budget)
        batch_scope = FollowImportBatch.scheduler_owned
        budget_attrs = {
          global_base_budget: base_budget,
          effective_global_budget: resolved.effective_budget,
        }
      else
        base_budget = FollowImport::ExecutionPolicy.shadow_plan_budget
        resolved = shadow_local_load(load_snapshot, base_budget)
        batch_scope = FollowImportBatch.all
        budget_attrs = {
          shadow_plan_budget: base_budget,
          effective_shadow_plan_budget: resolved.effective_budget,
        }
      end

      decision = resolved.decision
      effective_budget = resolved.effective_budget

      cursor = FollowImport::FairnessCursor.new.read
      owners, skipped = FollowImport::PendingBatchSource.new(batch_scope: batch_scope).owner_work(cursor: cursor)
      scheduled = FollowImport::FairScheduler.new(budget: effective_budget, owners: owners, cursor: cursor).plan
      source = cursor.source
      persisted = FollowImport::FairnessCursor.new.write(
        scheduled.next_cursor,
        active_owner_keys: owners.map { |owner| owner[:key] },
        active_batch_ids: owners.flat_map { |owner| owner[:batches].map { |batch| batch[:id] } }
      )
      source = FollowImport::FairnessCursor::SOURCE_PERSIST_FAILED unless persisted

      FollowImport::DispatchPlan.observe(
        observed_at: observed_at,
        global_pending_count: FollowImport::DispatchCounts.global_pending,
        active_batch_count: FollowImport::DispatchCounts.active_batches,
        execution_config: execution_config.merge(
          'local_load_profile_digest' => decision&.profile_digest,
          'local_load_profile_source' => decision&.profile_source
        ).compact,
        planning: {
          planned: true,
          scheduler_mode: mode_name(mode),
          entries: scheduled.planned,
          skipped_missing_owner_count: skipped,
          fairness_state_source: source,
          local_load: decision,
          local_load_fallback_used: resolved.fallback_used,
          executable_owner_count: owners.size,
          executable_batch_count: owners.sum { |owner| owner[:batches].size },
          claimed_count: 0,
        }.merge(budget_attrs)
      )
    end

    def global_local_load(load_snapshot, base_budget)
      FollowImport::LocalLoadEnforcement.evaluate(
        load_snapshot: load_snapshot,
        base_budget: base_budget
      )
    end

    def shadow_local_load(load_snapshot, base_budget)
      unless FollowImport::ExecutionPolicy.local_load_shadow_enabled?
        return FollowImport::LocalLoadBudget::Result.new(
          decision: FollowImport::LocalLoadDecision.disabled(base_budget),
          base_budget: base_budget.to_i,
          effective_budget: base_budget.to_i,
          fallback_used: nil
        )
      end

      profile = FollowImport::LocalLoadProfile.from_env
      FollowImport::LocalLoadBudget.resolve(
        snapshot: load_snapshot,
        base_budget: base_budget,
        profile: profile
      )
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('local_load_decision', e)
      FollowImport::LocalLoadBudget.apply(
        decision: FollowImport::LocalLoadDecision.evaluation_error(base_budget),
        profile: nil,
        base_budget: base_budget
      )
    end

    def capture_load_snapshot
      [FollowImport::LoadSnapshot.capture, nil]
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('dispatch_tick_load', e)
      [nil, e.class.name]
    end

    def record_tick(**attrs)
      FollowImport::DispatchTickObserver.record(attrs)
    end

    def mode_name(mode)
      mode.to_s.presence || 'shadow'
    end

    def error_outcome(mode)
      mode == :global ? OUTCOME_GLOBAL_ERROR : OUTCOME_SHADOW_ERROR
    end

    def execution_config
      {
        'schema' => FollowImport::DispatchTickObserver::SCHEMA_NAME,
        'schema_version' => FollowImport::DispatchTickObserver::SCHEMA_VERSION,
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
  end
end
