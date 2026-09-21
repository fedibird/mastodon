# frozen_string_literal: true

# Global Follow Import dispatcher tick.
#
# Modes (one tick, one durable lease, one budget, one plan):
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
# A GLOBAL effective budget of 0 skips owner/batch/target discovery
# and does not write the fairness cursor.
#
# The durable DispatchLease row + fencing generation is the real
# single-flight boundary and covers snapshot, budget, planning,
# claims, enqueue, and telemetry. Session advisory locks are not used.
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

      status = FollowImport::DispatchLease.with_lease do |handle|
        run_acquired(tick_id, observed_at, mode, handle)
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

    def run_acquired(tick_id, observed_at, mode, handle)
      load_snapshot, load_error = capture_load_snapshot
      plan = nil
      execution = nil

      plan = build_plan(observed_at, load_snapshot, mode)
      execution = execute_global(plan, handle) if mode == :global
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

    def execute_global(plan, handle)
      if plan.nil? || !plan.planned? || plan.entries.empty?
        return FollowImport::DispatchExecutor::Result.new(
          claimed_count: 0,
          skipped_stale_count: 0,
          skipped_unrecoverable_count: 0,
          skipped_wrong_owner_count: 0,
          error_class: nil,
          stopped: false
        )
      end

      FollowImport::DispatchExecutor.new(now: plan.observed_at, lease: handle).execute(plan.entries)
    end

    def build_plan(observed_at, load_snapshot, mode) # rubocop:disable Metrics/MethodLength
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

      # Authoritative GLOBAL: a zero effective budget must not discover
      # the pending universe, walk target feeds, move the fairness
      # cursor, or instantiate remote admission / DFT state. Shadow
      # observation keeps today's discover-and-plan-0 path.
      if mode == :global && effective_budget.to_i <= 0
        return observe_plan(
          observed_at: observed_at,
          decision: decision,
          resolved: resolved,
          budget_attrs: budget_attrs,
          scheduler_mode: mode_name(mode),
          entries: [],
          skipped_missing_owner_count: nil,
          fairness_state_source: nil,
          executable_owner_count: nil,
          executable_batch_count: nil,
          measure_backlog: false,
          remote: cheap_remote_identity(mode)
        )
      end

      remote = remote_admission_context(mode)
      cursor = FollowImport::FairnessCursor.new.read
      owners, skipped = FollowImport::PendingBatchSource.new(
        batch_scope: batch_scope,
        scan_policy: remote[:scan_policy]
      ).owner_work(cursor: cursor)
      scheduled = FollowImport::FairScheduler.new(
        budget: effective_budget,
        owners: owners,
        cursor: cursor,
        admission: remote[:admission],
        scan_policy: remote[:scan_policy]
      ).plan
      source = cursor.source
      persisted = FollowImport::FairnessCursor.new.write(
        scheduled.next_cursor,
        active_owner_keys: owners.map { |owner| owner[:key] },
        active_batch_ids: owners.flat_map { |owner| owner[:batches].map { |batch| batch[:id] } }
      )
      source = FollowImport::FairnessCursor::SOURCE_PERSIST_FAILED unless persisted

      observe_plan(
        observed_at: observed_at,
        decision: decision,
        resolved: resolved,
        budget_attrs: budget_attrs,
        scheduler_mode: mode_name(mode),
        entries: scheduled.planned,
        skipped_missing_owner_count: skipped,
        fairness_state_source: source,
        executable_owner_count: owners.size,
        executable_batch_count: owners.sum { |owner| owner[:batches].size },
        measure_backlog: true,
        remote: remote_plan_facts(remote, scheduled)
      )
    end

    def observe_plan(observed_at:, decision:, resolved:, budget_attrs:, scheduler_mode:, entries:, skipped_missing_owner_count:, fairness_state_source:, executable_owner_count:, executable_batch_count:, measure_backlog:, remote: {}) # rubocop:disable Metrics/ParameterLists
      FollowImport::DispatchPlan.observe(
        observed_at: observed_at,
        global_pending_count: measure_backlog ? FollowImport::DispatchCounts.global_pending : nil,
        active_batch_count: measure_backlog ? FollowImport::DispatchCounts.active_batches : nil,
        execution_config: execution_config.merge(
          'local_load_profile_digest' => decision&.profile_digest,
          'local_load_profile_source' => decision&.profile_source
        ).merge(remote_execution_config(remote)).compact,
        planning: {
          planned: true,
          scheduler_mode: scheduler_mode,
          entries: entries,
          skipped_missing_owner_count: skipped_missing_owner_count,
          fairness_state_source: fairness_state_source,
          local_load: decision,
          local_load_fallback_used: resolved.fallback_used,
          executable_owner_count: executable_owner_count,
          executable_batch_count: executable_batch_count,
          claimed_count: 0,
        }.merge(budget_attrs).merge(remote_planning_attrs(remote))
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
        'lease_strategy' => FollowImport::DispatchLease::STRATEGY,
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

    def cheap_remote_identity(mode)
      return {} unless mode == :global

      enabled = FollowImport::ExecutionPolicy.remote_admission_enforcement_enabled?
      adaptive_on = FollowImport::ExecutionPolicy.remote_adaptive_shadow_enabled?
      facts = {
        remote_admission_enabled: enabled,
        remote_admission_configured: nil,
        profile: nil,
        adaptive_remote_shadow_enabled: adaptive_on,
        adaptive_remote_configured: nil,
        adaptive_profile: nil,
      }
      if enabled || adaptive_on
        profile = FollowImport::RemoteAdmissionProfile.from_env
        facts[:profile] = profile
        if enabled
          facts[:remote_admission_configured] = profile.configured?
          facts[:remote_profile_version] = profile.version if profile.configured?
          warn_remote_misconfiguration(profile) unless profile.configured?
        end
      end
      facts.merge!(cheap_adaptive_identity(facts[:profile], adaptive_on))
      facts
    end

    def cheap_adaptive_identity(fixed_profile, adaptive_on)
      return {} unless adaptive_on

      adaptive = FollowImport::AdaptiveRemoteProfile.from_env
      facts = { adaptive_profile: adaptive, adaptive_remote_configured: false }
      unless adaptive.configured?
        warn_adaptive_misconfiguration(adaptive)
        return facts
      end
      compatibility = FollowImport::AdaptiveRemoteCompatibility.check(adaptive, fixed_profile)
      unless compatibility.ok
        warn_adaptive_misconfiguration(adaptive, compatibility.error)
        return facts
      end

      facts[:adaptive_remote_configured] = true
      facts[:adaptive_profile_version] = adaptive.version
      facts
    end

    def remote_admission_context(mode)
      identity = cheap_remote_identity(mode)
      return identity unless mode == :global

      # One memoized PR F runtime snapshot per GLOBAL tick. Adaptive
      # shadow may reuse it for destination → origin mapping even when
      # fixed enforcement is off. Do not construct RemoteAdmission,
      # UnavailableDomain, or fixed dest/origin suppression just to
      # obtain that mapping.
      runtime = shared_runtime_snapshot(identity)

      admission = nil
      if identity[:remote_admission_enabled] && identity[:profile]&.configured?
        hosts, hosts_ok = FollowImport::RemoteAdmission.unavailable_hosts
        admission = FollowImport::RemoteAdmission.new(
          profile: identity[:profile],
          runtime: runtime,
          unavailable_hosts: hosts,
          unavailable_snapshot_available: hosts_ok,
          now: Time.now.utc
        )
        identity[:scan_policy] = identity[:profile].scan_policy
      end

      identity[:admission] = wrap_adaptive_shadow(admission, identity, runtime)
      identity.delete(:admission) if identity[:admission].nil?
      identity
    end

    def shared_runtime_snapshot(identity)
      return unless identity[:profile]&.configured?
      return unless identity[:remote_admission_enabled] || identity[:adaptive_remote_configured]

      FollowImport::RemoteRuntimeState.new(profile: identity[:profile]).snapshot
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('remote_runtime_state', e)
      nil
    end

    def wrap_adaptive_shadow(admission, identity, runtime)
      return admission unless identity[:adaptive_remote_shadow_enabled]
      return admission unless identity[:adaptive_remote_configured]
      return admission if identity[:adaptive_profile].nil? || identity[:profile].nil?

      state = FollowImport::AdaptiveRemoteState.new(
        adaptive_profile: identity[:adaptive_profile],
        fixed_profile: identity[:profile]
      ).snapshot
      FollowImport::AdaptiveRemoteAdvisor.new(
        admission: admission || FollowImport::RemoteAdmission::NullAdmission.new,
        adaptive_profile: identity[:adaptive_profile],
        fixed_profile: identity[:profile],
        state: state,
        runtime: runtime
      )
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('adaptive_remote_shadow', e)
      admission
    end

    def remote_plan_facts(remote, scheduled)
      facts = remote.slice(
        :remote_admission_enabled,
        :remote_admission_configured,
        :remote_profile_version,
        :profile,
        :adaptive_remote_shadow_enabled,
        :adaptive_remote_configured,
        :adaptive_profile_version
      )
      return facts unless remote[:admission]&.evaluated?

      facts.merge(scheduled.admission_stats || {})
    end

    def remote_planning_attrs(remote)
      remote.to_h.symbolize_keys.except(:admission, :scan_policy, :profile, :adaptive_profile)
    end

    def remote_execution_config(remote)
      config = {}
      profile = remote[:profile]
      config.merge!(profile.identity) if profile&.configured?
      adaptive = remote[:adaptive_profile]
      config.merge!(adaptive.identity) if adaptive&.configured?
      config
    end

    def warn_remote_misconfiguration(profile)
      message = profile.invalid? ? profile.error.to_s : 'unconfigured'
      FollowImport::Telemetry.warn_failure(
        'remote_admission_profile',
        StandardError.new(message)
      )
    end

    def warn_adaptive_misconfiguration(profile, extra = nil)
      message = extra.presence || (profile.invalid? ? profile.error.to_s : 'unconfigured')
      FollowImport::Telemetry.warn_failure(
        'adaptive_remote_profile',
        StandardError.new(message)
      )
    end
  end
end
