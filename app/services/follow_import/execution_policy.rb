# frozen_string_literal: true

# Single source of truth for follow-import execution timing/pacing knobs, so no
# timeout or batch size is hard-coded across workers/services.
#
# response_wait is how long a delivered target waits for an Accept/Reject before
# the periodic sweeper transitions it to completed_no_response.
#
# execution_batch_size / execution_reschedule_in pace the DB-backed batch
# executor: it claims at most execution_batch_size pending targets per pass and
# reschedules the next pass after execution_reschedule_in — but only while it is
# still making forward progress (see BatchExecutionWorker).
#
# All values here are PROVISIONAL / UNCALIBRATED and env-overridable — they
# should be tuned from real operational behaviour; no "correct" number is fixed.
#
# gate_enforcement_enabled? is OFF by default: the follow gate is observed/logged
# during execution but must NOT affect it unless an operator explicitly opts in
# with the experimental flag. No real Follow Import friction ships enabled.
#
# dispatch_global_enabled? is OFF by default. When true, NEW successfully
# recorded FollowImportBatch rows are scheduler-owned. Existing stored
# dispatch_owner is never rewritten from the current ENV.
# dispatch_shadow_enabled? remains the diagnostic planner. When GLOBAL is
# on it takes precedence for the single scheduler tick (one lease, one
# budget, one plan). When both flags are off the scheduler is a cheap no-op.
#
# local_load_shadow_enabled? is a default-off flag for hypothetical shadow
# interpretation only. Real GLOBAL claims use LocalLoadEnforcement /
# FOLLOW_IMPORT_LOCAL_LOAD_ENFORCEMENT, never the shadow flag.
# local_load_enforcement_enabled? is independent of DISPATCH_SHADOW.
# When true AND an enforcement-capable (v2 + explicit fallback) profile
# is configured, both the legacy BatchExecutionWorker and the
# authoritative global tick may shrink or zero their own base budget.
module FollowImport
  module ExecutionPolicy
    module_function

    RESPONSE_WAIT = 48.hours

    DEFAULT_BATCH_SIZE     = 50
    DEFAULT_RESCHEDULE_IN  = 30.seconds

    # Provisional / UNCALIBRATED cadence for the global dispatcher
    # (shadow observation or authoritative claiming). Shared with
    # config/sidekiq.yml (same ENV + same default). This is NOT
    # FOLLOW_IMPORT_EXECUTION_INTERVAL.
    DISPATCH_INTERVAL_ENV = 'FOLLOW_IMPORT_DISPATCH_INTERVAL'
    DISPATCH_INTERVAL_ALIAS_ENV = 'FOLLOW_IMPORT_DISPATCH_SHADOW_INTERVAL'
    DEFAULT_DISPATCH_INTERVAL_SECONDS = 60
    DEFAULT_DISPATCH_INTERVAL = DEFAULT_DISPATCH_INTERVAL_SECONDS.seconds

    # Compatibility names for the deprecated shadow-only ENV / APIs.
    DISPATCH_SHADOW_INTERVAL_ENV = DISPATCH_INTERVAL_ALIAS_ENV
    DEFAULT_DISPATCH_SHADOW_INTERVAL_SECONDS = DEFAULT_DISPATCH_INTERVAL_SECONDS
    DEFAULT_DISPATCH_SHADOW_INTERVAL = DEFAULT_DISPATCH_INTERVAL

    def response_wait
      RESPONSE_WAIT
    end

    def response_deadline_at(from = Time.now.utc)
      from + response_wait
    end

    def execution_batch_size
      size = ENV['FOLLOW_IMPORT_EXECUTION_BATCH_SIZE'].to_i
      size.positive? ? size : DEFAULT_BATCH_SIZE
    end

    def execution_reschedule_in
      seconds = ENV['FOLLOW_IMPORT_EXECUTION_INTERVAL'].to_i
      seconds.positive? ? seconds.seconds : DEFAULT_RESCHEDULE_IN
    end

    # Experimental. When false (default) the executor ignores the gate's proposal
    # entirely and executes at its normal pace; the gate is still evaluated and
    # logged for observation.
    def gate_enforcement_enabled?
      ENV['FOLLOW_IMPORT_GATE_ENFORCEMENT'].to_s == 'true'
    end

    # Authoritative global dispatcher for NEW follow-import batches.
    # Default off: new batches stay legacy-owned. When true, newly
    # created batches are scheduler-owned. Does not rewrite stored
    # dispatch_owner on existing rows.
    def dispatch_global_enabled?
      ENV['FOLLOW_IMPORT_DISPATCH_GLOBAL'].to_s == 'true'
    end

    # Intended owner for a NEW FollowImportBatch. Once a row exists,
    # stored dispatch_owner is the source of truth — do not re-read
    # this after record_batch / record_batch!.
    def intended_dispatch_owner
      dispatch_global_enabled? ? :scheduler : :legacy
    end

    # Shadow-only global dispatcher. Default off: the scheduler is a cheap no-op
    # unless dispatch_global_enabled? is also on. When true and GLOBAL is off,
    # one process may hold FollowImport::DispatchLease, build an account-first
    # shadow plan, and write tick telemetry. It must not claim.
    def dispatch_shadow_enabled?
      ENV['FOLLOW_IMPORT_DISPATCH_SHADOW'].to_s == 'true'
    end

    # Effective scheduler activation. GLOBAL wins over SHADOW when both
    # are on; both off is a cheap no-op.
    def dispatch_scheduler_mode
      return :global if dispatch_global_enabled?
      return :shadow if dispatch_shadow_enabled?

      nil
    end

    def dispatch_enabled?
      !dispatch_scheduler_mode.nil?
    end

    # Canonical cadence. FOLLOW_IMPORT_DISPATCH_INTERVAL wins when set
    # to a positive integer. Otherwise the deprecated
    # FOLLOW_IMPORT_DISPATCH_SHADOW_INTERVAL alias is accepted.
    def dispatch_interval_seconds
      seconds = ENV[DISPATCH_INTERVAL_ENV].to_i
      seconds = ENV[DISPATCH_INTERVAL_ALIAS_ENV].to_i unless seconds.positive?
      seconds.positive? ? seconds : DEFAULT_DISPATCH_INTERVAL_SECONDS
    end

    def dispatch_interval
      dispatch_interval_seconds.seconds
    end

    # sidekiq-scheduler `every` string. Must stay aligned with
    # config/sidekiq.yml, which reads the same ENV pair and default.
    def dispatch_every
      "#{dispatch_interval_seconds}s"
    end

    def dispatch_shadow_interval_seconds
      dispatch_interval_seconds
    end

    def dispatch_shadow_interval
      dispatch_interval
    end

    def dispatch_shadow_every
      dispatch_every
    end

    # Diagnostic / UNCALIBRATED shadow planning budget. Does not control
    # real Follow Import execution. Defaults to the current legacy
    # execution_batch_size so shadow plans are easy to compare with
    # BatchExecutionWorker. Never use this as the production GLOBAL budget.
    def shadow_plan_budget
      size = ENV['FOLLOW_IMPORT_DISPATCH_SHADOW_PLAN_BUDGET'].to_i
      size.positive? ? size : execution_batch_size
    end

    # Provisional / UNCALIBRATED global per-tick BASE ceiling for
    # authoritative claiming. Not a remote-server capacity estimate,
    # retry-attempt cap, or moderation limit. Defaults to
    # execution_batch_size. LocalLoadEnforcement may shrink or zero
    # this value; it must never raise the effective budget above it.
    def global_dispatch_budget
      size = ENV['FOLLOW_IMPORT_DISPATCH_GLOBAL_BUDGET'].to_i
      size.positive? ? size : execution_batch_size
    end

    # Shadow-only local-load controller. Default off. When true AND
    # dispatch_shadow_enabled? (and GLOBAL is off), the scheduler may
    # shrink the hypothetical shadow plan from a configured UNCALIBRATED
    # profile. Must not control real GLOBAL claims.
    def local_load_shadow_enabled?
      ENV['FOLLOW_IMPORT_LOCAL_LOAD_SHADOW'].to_s == 'true'
    end

    # Optional local-load enforcement. Default off.
    # Independent of FOLLOW_IMPORT_DISPATCH_SHADOW / local_load_shadow.
    # When false, BatchExecutionWorker uses execution_batch_size and the
    # global tick uses the finite global_dispatch_budget. When true, a
    # valid enforcement-capable profile is still required or the pass /
    # tick stays at its own base budget.
    def local_load_enforcement_enabled?
      ENV['FOLLOW_IMPORT_LOCAL_LOAD_ENFORCEMENT'].to_s == 'true'
    end

    # Fixed remote admission for scheduler-owned GLOBAL ticks.
    # Default off: the GLOBAL scheduler keeps PR C destination behavior
    # (finite global/local-load budget only). When true, a valid
    # RemoteAdmission profile is still required or the tick stays at
    # that PR C behavior and records remote_admission_configured=false.
    # Does not apply to BatchExecutionWorker / GLOBAL=false.
    def remote_admission_enforcement_enabled?
      ENV['FOLLOW_IMPORT_REMOTE_ADMISSION_ENFORCEMENT'].to_s == 'true'
    end
  end
end
