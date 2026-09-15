# frozen_string_literal: true

# Global Follow Import dispatcher tick. PR A+B is SHADOW ONLY.
#
# Flow:
#   shadow enabled? → acquire session advisory lease → load snapshot
#   → account-first shadow plan → record tick telemetry → release lease
#
# The plan is a point-in-time simulation, not a reservation. It must not
# transition FollowImportTarget rows, call TargetTransitionService#mark_queued,
# enqueue RelationshipWorker / DeliveryWorker, finalize/delete an Import,
# or change BatchExecutionWorker scheduling.
#
# claimed_count stays 0. planned_count is the shadow allocator result.
module FollowImport
  class DispatchScheduler
    OUTCOME_SHADOW_DISABLED = 'shadow_disabled'
    OUTCOME_LEASE_BUSY      = 'lease_busy'
    OUTCOME_SHADOW_OBSERVED = 'shadow_observed'
    OUTCOME_SHADOW_ERROR    = 'shadow_error'

    Result = Struct.new(:outcome, :lease_acquired, :plan, :tick_id, keyword_init: true)

    def call
      tick_id = SecureRandom.uuid
      observed_at = Time.now.utc

      unless FollowImport::ExecutionPolicy.dispatch_shadow_enabled?
        return Result.new(outcome: OUTCOME_SHADOW_DISABLED, lease_acquired: false, plan: nil, tick_id: tick_id)
      end

      status = FollowImport::DispatchLease.with_lease do
        observe_acquired(tick_id, observed_at)
      end

      return busy_result(tick_id, observed_at) if status == FollowImport::DispatchLease::BUSY

      status
    rescue StandardError => e
      record_tick(
        tick_id: tick_id,
        observed_at: observed_at,
        outcome: OUTCOME_SHADOW_ERROR,
        lease_acquired: false,
        error_class: e.class.name,
        metadata: { 'error_class' => e.class.name }
      )
      Result.new(outcome: OUTCOME_SHADOW_ERROR, lease_acquired: false, plan: nil, tick_id: tick_id)
    end

    private

    def busy_result(tick_id, observed_at)
      record_tick(
        tick_id: tick_id,
        observed_at: observed_at,
        outcome: OUTCOME_LEASE_BUSY,
        lease_acquired: false
      )
      Result.new(outcome: OUTCOME_LEASE_BUSY, lease_acquired: false, plan: nil, tick_id: tick_id)
    end

    def observe_acquired(tick_id, observed_at)
      load_snapshot, load_error = capture_load_snapshot
      plan = build_shadow_plan(observed_at)
      metadata = {}
      metadata['load_snapshot_error_class'] = load_error if load_error
      metadata['fairness_persist_failed'] = true if plan.fairness_state_source == FollowImport::FairnessCursor::SOURCE_PERSIST_FAILED

      record_tick(
        tick_id: tick_id,
        observed_at: observed_at,
        outcome: OUTCOME_SHADOW_OBSERVED,
        lease_acquired: true,
        plan: plan,
        load_snapshot: load_snapshot,
        metadata: metadata
      )

      Result.new(outcome: OUTCOME_SHADOW_OBSERVED, lease_acquired: true, plan: plan, tick_id: tick_id)
    rescue StandardError => e
      record_tick(
        tick_id: tick_id,
        observed_at: observed_at,
        outcome: OUTCOME_SHADOW_ERROR,
        lease_acquired: true,
        error_class: e.class.name,
        metadata: { 'error_class' => e.class.name }
      )
      Result.new(outcome: OUTCOME_SHADOW_ERROR, lease_acquired: true, plan: nil, tick_id: tick_id)
    end

    def build_shadow_plan(observed_at)
      cursor = FollowImport::FairnessCursor.new.read
      owners, skipped = FollowImport::PendingBatchSource.new.owner_work(cursor: cursor)
      budget = FollowImport::ExecutionPolicy.shadow_plan_budget
      scheduled = FollowImport::FairScheduler.new(budget: budget, owners: owners, cursor: cursor).plan
      source = cursor.source
      source = FollowImport::FairnessCursor::SOURCE_PERSIST_FAILED unless FollowImport::FairnessCursor.new.write(scheduled.next_cursor)

      FollowImport::DispatchPlan.observe(
        observed_at: observed_at,
        global_pending_count: FollowImport::DispatchCounts.global_pending,
        active_batch_count: FollowImport::DispatchCounts.active_batches,
        execution_config: execution_config,
        planned: true,
        entries: scheduled.entries,
        skipped_missing_owner_count: skipped,
        fairness_state_source: source,
        shadow_plan_budget: budget
      )
    end

    def capture_load_snapshot
      [FollowImport::LoadSnapshot.capture, nil]
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('dispatch_tick_load', e)
      [nil, e.class.name]
    end

    def record_tick(**attrs)
      FollowImport::DispatchTickObserver.record(**attrs)
    end

    def execution_config
      {
        'schema' => FollowImport::DispatchTickObserver::SCHEMA_NAME,
        'schema_version' => FollowImport::DispatchTickObserver::SCHEMA_VERSION,
        'execution_batch_size' => FollowImport::ExecutionPolicy.execution_batch_size,
        'execution_reschedule_in' => FollowImport::ExecutionPolicy.execution_reschedule_in.to_i,
        'gate_enforcement_enabled' => FollowImport::ExecutionPolicy.gate_enforcement_enabled?,
        'dispatch_shadow_enabled' => FollowImport::ExecutionPolicy.dispatch_shadow_enabled?,
        'dispatch_shadow_interval' => FollowImport::ExecutionPolicy.dispatch_shadow_interval.to_i,
        'shadow_plan_budget' => FollowImport::ExecutionPolicy.shadow_plan_budget,
        'plan_algorithm' => FollowImport::FairScheduler::ALGORITHM,
        'plan_schema_version' => FollowImport::FairScheduler::SCHEMA_VERSION,
      }
    end
  end
end
