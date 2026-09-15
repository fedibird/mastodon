# frozen_string_literal: true

# Resolves the *legacy per-pass* execution budget from LocalLoadGuard.
# This is not a global claim budget. Many BatchExecutionWorker passes
# may still run concurrently; PR C is the global fairness cutover.
#
# Flag off → effective = execution_batch_size, no guard evaluation.
# Flag on without an enforcement-capable (v2 + fallback) profile →
# legacy budget + rate-limited warning. Never freeze all imports.
# Flag on with a valid v2 profile → shrink or defer from the worker's
# own pre-dispatch LoadSnapshot. Runtime/controller failure uses the
# explicit profile fallback, never unlimited and never an invented number.
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
    end

    def evaluate
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

      profile = FollowImport::LocalLoadProfile.from_env
      return unconfigured_legacy(profile) unless profile.enforcement_capable?

      decision = FollowImport::LocalLoadGuard.evaluate(
        snapshot: @load_snapshot,
        base_budget: @base_budget,
        profile: profile
      )

      if decision.usable_recommendation?
        Result.new(
          enabled: true,
          configured: true,
          decision: decision,
          base_budget: @base_budget,
          effective_budget: clamp(decision.recommended_budget),
          fallback_used: false
        )
      elsif decision.unknown? || decision.evaluation_error?
        Result.new(
          enabled: true,
          configured: true,
          decision: decision,
          base_budget: @base_budget,
          effective_budget: clamp(profile.fallback_budget(@base_budget)),
          fallback_used: true
        )
      else
        unconfigured_legacy(profile, decision: decision)
      end
    end

    private

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

    def clamp(value)
      [[@base_budget, value.to_i].min, 0].max
    end
  end
end
