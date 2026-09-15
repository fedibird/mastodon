# frozen_string_literal: true

# Shared local-load budget resolution for shadow planning and legacy
# enforcement. The *base* budget may differ (shadow_plan_budget vs
# execution_batch_size); the control law must not.
#
#   usable recommendation → min(base, recommended)
#   unknown / evaluation_error + v2 fallback → min(base, fallback)
#   otherwise → base (disabled / unconfigured / invalid / v1 unknown)
#
# Never invents a fallback percentage. Never increases the supplied base.
# Does not query Sidekiq, claim targets, or look at accounts.
module FollowImport
  class LocalLoadBudget
    Result = Struct.new(:decision, :base_budget, :effective_budget, :fallback_used, keyword_init: true)

    def self.resolve(snapshot:, base_budget:, profile:)
      decision = FollowImport::LocalLoadGuard.evaluate(
        snapshot: snapshot,
        base_budget: base_budget,
        profile: profile
      )
      apply(decision: decision, profile: profile, base_budget: base_budget)
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('local_load_budget', e)
      apply(
        decision: FollowImport::LocalLoadDecision.evaluation_error(base_budget, profile),
        profile: profile,
        base_budget: base_budget
      )
    end

    def self.apply(decision:, profile:, base_budget:)
      base = base_budget.to_i
      if decision.usable_recommendation?
        Result.new(
          decision: decision,
          base_budget: base,
          effective_budget: clamp(base, decision.recommended_budget),
          fallback_used: false
        )
      elsif fallback_applicable?(decision, profile)
        Result.new(
          decision: decision,
          base_budget: base,
          effective_budget: clamp(base, profile.fallback_budget(base)),
          fallback_used: true
        )
      else
        Result.new(
          decision: decision,
          base_budget: base,
          effective_budget: base,
          fallback_used: false
        )
      end
    end

    def self.fallback_applicable?(decision, profile)
      (decision.unknown? || decision.evaluation_error?) && !profile&.fallback.nil?
    end
    private_class_method :fallback_applicable?

    def self.clamp(base, value)
      [[base, value.to_i].min, 0].max
    end
    private_class_method :clamp
  end
end
