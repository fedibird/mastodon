# frozen_string_literal: true

# Global Follow Import dispatcher tick. PR A is SHADOW ONLY.
#
# Flow:
#   shadow enabled? → acquire session advisory lease → read-only snapshot
#   → build a summary DispatchPlan → record tick telemetry → release lease
#
# This class must not transition FollowImportTarget rows, call
# TargetTransitionService#mark_queued, enqueue RelationshipWorker /
# DeliveryWorker, finalize/delete an Import, or change BatchExecutionWorker
# scheduling. BatchExecutionWorker remains the only real claimer.
#
# Sidekiq unique lock (on the Scheduler::* wrapper) is job dedup only.
# FollowImport::DispatchLease is the correctness boundary.
#
# retry: 0 on the Sidekiq wrapper: a raised tick must not replay work.
# There is no stored budget in PR A; the contract stays for later PRs.
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
      FollowImport::DispatchPlan.observe(
        observed_at: observed_at,
        global_pending_count: FollowImport::DispatchCounts.global_pending,
        active_batch_count: FollowImport::DispatchCounts.active_batches,
        execution_config: execution_config
      )
    end

    # Load is telemetry only. Do not classify NORMAL/BUSY/HEAVY/OVERLOADED
    # and do not stop legacy Follow Import workers. Capture failure → NULL.
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
      }
    end
  end
end
