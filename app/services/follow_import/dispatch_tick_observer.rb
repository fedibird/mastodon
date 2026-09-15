# frozen_string_literal: true

# Records one global Follow Import dispatch-scheduler tick.
# Observation only — never consulted to claim, pause, or slow execution.
#
# Per-batch FollowImportDispatchObservation rows stay tied to
# BatchExecutionWorker. Overloading them would make "this pass claimed N"
# vs "the global tick claimed 0" ambiguous, so ticks use a dedicated table.
#
# claimed_count is always 0 in PR A shadow mode. Insert failures are
# swallowed (rate-limited warning) and must not break the scheduler.
module FollowImport
  class DispatchTickObserver
    SCHEMA_NAME    = 'follow_import_dispatch_tick'
    SCHEMA_VERSION = 1

    def self.record(tick_id:, observed_at:, outcome:, lease_acquired:, plan: nil, load_snapshot: nil, error_class: nil, metadata: {})
      FollowImport::Telemetry.record_dispatch_tick(
        observed_at: observed_at,
        tick_id: tick_id,
        scheduler_mode: 'shadow',
        lease_acquired: lease_acquired,
        outcome: outcome,
        global_pending_count: plan&.global_pending_count,
        active_batch_count: plan&.active_batch_count,
        claimed_count: 0,
        load_snapshot: load_snapshot,
        execution_config: plan&.execution_config || execution_config,
        error_class: error_class,
        metadata: tick_metadata(metadata)
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
        'dispatch_shadow_enabled' => FollowImport::ExecutionPolicy.dispatch_shadow_enabled?,
        'dispatch_shadow_interval' => FollowImport::ExecutionPolicy.dispatch_shadow_interval.to_i,
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
