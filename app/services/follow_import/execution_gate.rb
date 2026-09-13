# frozen_string_literal: true

# Decides whether a follow-import batch executor pass may execute its claimed
# targets, from the adaptive follow gate's proposal for the importing account.
#
# SHADOW BY DEFAULT: the gate is always evaluated and logged for observation, but
# it does NOT affect execution unless the experimental
# FollowImport::ExecutionPolicy.gate_enforcement_enabled? flag is on. No real
# Follow Import friction ships enabled.
#
# When enforcement IS enabled, the reversible friction maps to a per-pass
# execution decision only (there is deliberately no persisted deferred/review
# state; delay/review just leave the target pending for this pass):
#
#   allow            -> execute normally
#   rate_limit       -> execute (the executor is already bounded/paced)
#   confirm_target   -> execute (interactive confirmation is not attempted in an
#                       import; treated as shadow-only / non-blocking here)
#   delay            -> leave pending for this pass
#   moderator_review -> leave pending for this pass
#
# The follow-import mechanism is never itself a risk signal; the target context
# is uniform ("remote") because local targets have no remote round-trip to gate.
module FollowImport
  class ExecutionGate
    EXECUTE_FRICTIONS = %w(allow rate_limit confirm_target).freeze
    CONTEXT           = { 'mechanism' => 'follow_import', 'target_locality' => 'remote', 'target_locked' => false }.freeze

    attr_reader :friction, :decision

    def self.for_account(account, now: Time.now.utc)
      new(account, now: now)
    end

    def initialize(account, now: Time.now.utc)
      @account  = account
      @now      = now
      @decision = evaluate
      @friction = @decision.is_a?(Hash) ? @decision['proposed_friction'] : 'allow'
    end

    # Whether this pass may execute its claimed targets. Shadow-by-default: unless
    # enforcement is explicitly enabled, always true (the gate is observed only).
    def execute?
      return true unless FollowImport::ExecutionPolicy.gate_enforcement_enabled?

      EXECUTE_FRICTIONS.include?(@friction)
    end

    # Structured observation for logging (what the gate WOULD do), independent of
    # whether it is enforced.
    def observation
      {
        'shadow'         => !FollowImport::ExecutionPolicy.gate_enforcement_enabled?,
        'would_friction' => @friction,
        'would_execute'  => execute?,
        'enforced'       => FollowImport::ExecutionPolicy.gate_enforcement_enabled?,
        'policy_version' => @decision.is_a?(Hash) ? @decision['policy_version'] : nil,
        'params_digest'  => @decision.is_a?(Hash) ? @decision['params_digest'] : nil,
        'subject_id'     => @decision.is_a?(Hash) ? @decision['subject_id'] : nil,
      }
    end

    private

    def evaluate
      Moderation::AdaptiveFollowGateDecisionService.new.call(@account, context: CONTEXT, now: @now)
    rescue StandardError => e
      # Fail open: a gate error must never block a user's own import.
      Rails.logger.warn("[FollowImport::ExecutionGate] evaluation failed, failing open: #{e.class}: #{e.message}")
      nil
    end
  end
end
