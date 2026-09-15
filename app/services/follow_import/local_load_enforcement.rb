# frozen_string_literal: true

# Resolves the *legacy per-pass* execution budget from LocalLoadGuard.
# This is not a global claim budget. Many BatchExecutionWorker passes
# may still run concurrently; PR C is the global fairness cutover.
#
# This class is a failure boundary: evaluate never raises into the
# worker. Flag off → effective = execution_batch_size, no guard
# evaluation. Flag on without an enforcement-capable (v2 + fallback)
# profile → legacy budget + rate-limited warning. Once a capable
# profile is in hand, unexpected controller/resolver errors use that
# profile's explicit fallback and are recorded as evaluation_error,
# never invalid or unlimited.
module FollowImport
  class LocalLoadEnforcement
    class NotConfigured < StandardError; end

    Result = Struct.new(
      :enabled,
      :configured,
      :decision,
      :base_budget,
      :effective_budget,
      :fallback_used,
      keyword_init: true
    ) do
      def skip_selection?
        enabled && configured && effective_budget.to_i <= 0
      end
    end

    def self.evaluate(load_snapshot:, base_budget:)
      new(load_snapshot: load_snapshot, base_budget: base_budget).evaluate
    end

    def initialize(load_snapshot:, base_budget:)
      @load_snapshot = load_snapshot
      @base_budget = base_budget.to_i
      @profile = nil
    end

    def evaluate
      resolve
    rescue StandardError => e
      safe_result(e)
    end

    private

    def resolve
      unless FollowImport::ExecutionPolicy.local_load_enforcement_enabled?
        return Result.new(
          enabled: false,
          configured: nil,
          decision: nil,
          base_budget: @base_budget,
          effective_budget: @base_budget,
          fallback_used: nil
        )
      end

      @profile = FollowImport::LocalLoadProfile.from_env
      return unconfigured_legacy(@profile) unless @profile.enforcement_capable?

      resolved = FollowImport::LocalLoadBudget.resolve(
        snapshot: @load_snapshot,
        base_budget: @base_budget,
        profile: @profile
      )
      Result.new(
        enabled: true,
        configured: true,
        decision: resolved.decision,
        base_budget: @base_budget,
        effective_budget: resolved.effective_budget,
        fallback_used: resolved.fallback_used
      )
    end

    def safe_result(error)
      FollowImport::Telemetry.warn_failure('local_load_enforcement', error)
      return capable_fallback_result if @profile&.enforcement_capable?

      unconfigured_legacy(@profile || FollowImport::LocalLoadProfile.unconfigured)
    end

    def capable_fallback_result
      decision = FollowImport::LocalLoadDecision.evaluation_error(@base_budget, @profile)
      Result.new(
        enabled: true,
        configured: true,
        decision: decision,
        base_budget: @base_budget,
        effective_budget: FollowImport::LocalLoadBudget.apply(
          decision: decision,
          profile: @profile,
          base_budget: @base_budget
        ).effective_budget,
        fallback_used: true
      )
    end

    def unconfigured_legacy(profile, decision: nil)
      FollowImport::Telemetry.warn_failure(
        'local_load_enforcement',
        NotConfigured.new(profile.invalid? ? 'invalid' : 'not_enforcement_capable')
      )

      Result.new(
        enabled: true,
        configured: false,
        decision: decision || unconfigured_decision(profile),
        base_budget: @base_budget,
        effective_budget: @base_budget,
        fallback_used: false
      )
    end

    def unconfigured_decision(profile)
      if profile.invalid?
        FollowImport::LocalLoadDecision.invalid(@base_budget, profile)
      elsif profile.configured?
        FollowImport::LocalLoadDecision.unconfigured(
          @base_budget,
          profile,
          reasons: %w(enforcement_profile_required)
        )
      else
        FollowImport::LocalLoadDecision.unconfigured(@base_budget, profile)
      end
    end
  end
end
