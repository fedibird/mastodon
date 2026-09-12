# frozen_string_literal: true

# Proposes an adaptive, REVERSIBLE friction for an individual follow attempt, from
# a subject's risk evaluation plus the attempt context. This is a decision-only /
# shadow layer:
#
#   * Decision-only, no execution — it returns a *proposed* friction and changes
#     nothing. It performs no enforcement, executes no action, and never denies or
#     suspends. FollowService / ImportService are untouched by this PR.
#   * Reversible frictions only — allow / rate_limit / confirm_target / delay /
#     moderator_review. No deny/hard-block here.
#   * Separate policy from Moderation::ModeratorRecommendationService: that ranks
#     a subject for human review; this proposes friction for one follow attempt.
#     Both read the same evaluation but are independent, versioned policies.
#   * Behaviour-centric, mechanism-agnostic — the attempt mechanism (manual_ui /
#     api / follow_import / migration) is echoed for observability but NEVER
#     raises risk, because abusers channel-shift between mechanisms. Follow-import
#     is not itself a risk signal, and unresolved_target_ratio is NOT used as an
#     unknown-relationship proxy.
#   * No inference of unimplemented features — relationship context in the attempt
#     is echoed but not used for risk (relationship-aware scoring is not built yet).
#   * Read-only, versioned & auditable — policy_version + params_digest identify
#     the policy; matched_rules carry each firing condition's value + minimum.
#
# Thresholds in DEFAULT_PARAMS are INITIAL and UNCALIBRATED (and injectable).
module Moderation
  class AdaptiveFollowGateDecisionService
    POLICY_VERSION = 'follow-gate-decision-v0-2026-09-12'

    # Reversible frictions, ordered least -> most (used to pick the strongest
    # matched proposal). There is deliberately no "deny".
    FRICTIONS = %w(allow rate_limit confirm_target delay moderator_review).freeze

    TARGET_LOCALITIES = %w(local remote).freeze

    DEFAULT_PARAMS = {
      # Strongest reversible friction: sustained rejection by multiple independent
      # responders AND continued contact after the first negative signal.
      'moderator_review' => { 'rejection_min' => 0.8, 'repeat_behavior_min' => 0.6 },
      # Slow the attempt down so rejection feedback can arrive before more follows.
      'delay' => { 'velocity_min' => 0.6, 'remote_or_unknown_rejection_min' => 0.5 },
      # Local UNLOCKED recipient can confirm; only meaningful for a target that
      # would otherwise be followed immediately (locked targets already confirm).
      'confirm_target' => { 'local_rejection_min' => 0.5 },
      # Lightest friction for elevated volume/velocity.
      'rate_limit' => { 'contact_volume_min' => 0.5, 'velocity_min' => 0.5 },
    }.freeze

    def initialize(evaluator: Moderation::RiskEvaluationService.new, params: DEFAULT_PARAMS, policy_version: nil)
      @evaluator      = evaluator
      @params         = params
      @policy_version = policy_version || (params == DEFAULT_PARAMS ? POLICY_VERSION : 'custom')
      @params_digest  = digest(@params)
    end

    # +context+ describes the follow attempt. Recognised keys: mechanism,
    # target_locality ('local'/'remote'), target_locked, relationship_context.
    # Only target_locality influences the proposal (locality routes confirm vs
    # delay); the rest are echoed for observability but never raise risk.
    def call(subject_or_account, context: {}, now: Time.now.utc)
      evaluation = @evaluator.call(subject_or_account, now: now)
      scores     = subscore_map(evaluation)
      normalized = normalize_context(context)
      matched    = matched_rules(scores, normalized)

      {
        'policy_version'    => @policy_version,
        'params_digest'     => @params_digest,
        'subject_id'        => evaluation['subject_id'],
        'generated_at'      => now.iso8601,
        'context'           => normalized,
        # Shadow proposal only — nothing is executed and nothing is denied.
        'proposed_friction' => strongest_friction(matched),
        'shadow'            => true,
        'matched_rules'     => matched,
        'evaluation'        => evaluation,
      }
    end

    private

    def subscore_map(evaluation)
      (evaluation['subscores'] || {}).transform_values { |sub| sub['score'].to_f }
    end

    def normalize_context(context)
      context ||= {}
      locality = context['target_locality'] || context[:target_locality]
      locality = nil unless TARGET_LOCALITIES.include?(locality)

      {
        # Echoed for observability; mechanism NEVER changes the proposal.
        'mechanism'            => context['mechanism'] || context[:mechanism],
        'target_locality'      => locality,
        'target_locked'        => context['target_locked'].nil? ? context[:target_locked] : context['target_locked'],
        # Echoed but NOT used for risk (relationship-aware scoring not implemented).
        'relationship_context' => context['relationship_context'] || context[:relationship_context],
      }
    end

    def matched_rules(scores, context)
      rules    = []
      locality = context['target_locality']

      review = @params['moderator_review']
      if scores['rejection'].to_f >= review['rejection_min'] && scores['repeat_behavior'].to_f >= review['repeat_behavior_min']
        rules << rule('moderator_review', 'sustained_rejection_with_continuation',
                      'rejection' => condition(scores['rejection'], review['rejection_min']),
                      'repeat_behavior' => condition(scores['repeat_behavior'], review['repeat_behavior_min']))
      end

      delay = @params['delay']
      rules << rule('delay', 'high_velocity', 'velocity' => condition(scores['velocity'], delay['velocity_min'])) if scores['velocity'].to_f >= delay['velocity_min']
      if locality != 'local' && scores['rejection'].to_f >= delay['remote_or_unknown_rejection_min']
        rules << rule('delay', 'elevated_rejection_non_local_target',
                      'rejection' => condition(scores['rejection'], delay['remote_or_unknown_rejection_min']),
                      'target_locality' => locality)
      end

      # confirm_target only adds friction to a follow that would otherwise be
      # immediate: a LOCAL, UNLOCKED target. A locked local target already goes
      # through follow-request approval, so proposing confirmation there is
      # redundant (and would inflate shadow counts). Unknown locked state (nil)
      # is treated as not-applicable, so it does not fire either.
      confirm = @params['confirm_target']
      if locality == 'local' && context['target_locked'] == false && scores['rejection'].to_f >= confirm['local_rejection_min']
        rules << rule('confirm_target', 'elevated_rejection_local_unlocked_target',
                      'rejection' => condition(scores['rejection'], confirm['local_rejection_min']),
                      'target_locality' => 'local',
                      'target_locked' => false)
      end

      rate = @params['rate_limit']
      rules << rule('rate_limit', 'elevated_contact_volume', 'contact_volume' => condition(scores['contact_volume'], rate['contact_volume_min'])) if scores['contact_volume'].to_f >= rate['contact_volume_min']
      rules << rule('rate_limit', 'elevated_velocity', 'velocity' => condition(scores['velocity'], rate['velocity_min'])) if scores['velocity'].to_f >= rate['velocity_min']

      rules
    end

    def rule(friction, name, conditions)
      { 'friction' => friction, 'rule' => name, 'conditions' => conditions }
    end

    def condition(value, minimum)
      { 'value' => value.to_f, 'minimum' => minimum }
    end

    def strongest_friction(matched)
      matched.map { |r| r['friction'] }.max_by { |friction| FRICTIONS.index(friction) || -1 } || 'allow'
    end

    def digest(params)
      "sha256:#{Digest::SHA256.hexdigest(canonicalize(params).to_json)}"
    end

    def canonicalize(object)
      case object
      when Hash then object.keys.sort_by(&:to_s).to_h { |key| [key.to_s, canonicalize(object[key])] }
      when Array then object.map { |element| canonicalize(element) }
      else object
      end
    end
  end
end
