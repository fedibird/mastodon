# frozen_string_literal: true

# Maps a subject's risk *evaluation* (Moderation::RiskEvaluationService sub-scores)
# to an ADVISORY moderator-review tier. This is the decision-policy layer, kept
# separate from evaluation and from execution:
#
#   * Advisory only — the output is a review recommendation for a human
#     (normal / watch / review_recommended / urgent_review). It performs NO
#     enforcement and executes NO action; it just tells a moderator what to look
#     at first. There is no action/enforcement in the output.
#   * Read-only — it computes the evaluation (itself read-only) and writes nothing.
#   * Explainable & auditable — every recommendation lists the matched rules and
#     the sub-scores that triggered them, and embeds the full evaluation (with its
#     reason codes). policy_version + params_digest identify the policy.
#   * No single score — tiers come from transparent rules over individual
#     sub-scores, not from summing them into one number.
#
# The thresholds in DEFAULT_PARAMS are INITIAL and UNCALIBRATED (and injectable),
# to be tuned from real cohorts before this is wired to anything beyond a review
# queue. Nothing here escalates on a single block/mute (the rejection sub-score
# already requires multiple independent responders) and follow-import remains
# deferred upstream.
module Moderation
  class ModeratorRecommendationService
    POLICY_VERSION = 'reco-policy-v0-2026-09-12'

    # Ordered from least to most urgent; used to pick the highest matched tier.
    TIERS = %w(normal watch review_recommended urgent_review).freeze

    DEFAULT_PARAMS = {
      # Strongest collective-harm shape: sustained rejection by multiple
      # independent responders AND continued contact after the first signal.
      'urgent_review' => {
        'rejection_min'       => 0.8,
        'repeat_behavior_min' => 0.6,
      },
      'review_recommended' => {
        'rejection_min' => 0.5, # multiple independent rejectors present
        'report_min'    => 0.4, # at least one report
        'contact_and_velocity' => { 'contact_volume_min' => 0.5, 'velocity_min' => 0.6 },
      },
      'watch' => {
        'any_subscore_min' => 0.5,
        # Explicit allowlist: only these dimensions can raise a watch. A new
        # sub-score added upstream (e.g. follow_import once relationship-aware
        # scoring lands) must be added here — with a policy_version bump — before
        # it can affect a recommendation. This keeps evaluation and decision
        # policy decoupled. follow_import is intentionally excluded for now.
        'dimensions' => %w(contact_volume velocity rejection report repeat_behavior),
      },
    }.freeze

    def initialize(evaluator: Moderation::RiskEvaluationService.new, params: DEFAULT_PARAMS, policy_version: nil)
      @evaluator      = evaluator
      @params         = params
      @policy_version = policy_version || (params == DEFAULT_PARAMS ? POLICY_VERSION : 'custom')
      @params_digest  = digest(@params)
    end

    def call(subject_or_account, now: Time.now.utc)
      evaluation = @evaluator.call(subject_or_account, now: now)
      scores     = subscore_map(evaluation)
      matched    = matched_rules(scores)

      {
        'policy_version' => @policy_version,
        'params_digest'  => @params_digest,
        'subject_id'     => evaluation['subject_id'],
        'generated_at'   => now.iso8601,
        # Advisory review tier for a human queue — NOT an enforcement action.
        'recommendation' => highest_tier(matched),
        'advisory'       => true,
        'matched_rules'  => matched,
        'evaluation'     => evaluation,
      }
    end

    private

    def subscore_map(evaluation)
      (evaluation['subscores'] || {}).transform_values { |sub| sub['score'].to_f }
    end

    def matched_rules(scores)
      rules = []

      urgent = @params['urgent_review']
      if scores['rejection'].to_f >= urgent['rejection_min'] && scores['repeat_behavior'].to_f >= urgent['repeat_behavior_min']
        rules << rule('urgent_review', 'sustained_rejection_with_continuation',
                      'rejection' => condition(scores['rejection'], urgent['rejection_min']),
                      'repeat_behavior' => condition(scores['repeat_behavior'], urgent['repeat_behavior_min']))
      end

      review = @params['review_recommended']
      rules << rule('review_recommended', 'multiple_independent_rejectors', 'rejection' => condition(scores['rejection'], review['rejection_min'])) if scores['rejection'].to_f >= review['rejection_min']
      rules << rule('review_recommended', 'reports_present', 'report' => condition(scores['report'], review['report_min'])) if scores['report'].to_f >= review['report_min']

      cv = review['contact_and_velocity']
      if scores['contact_volume'].to_f >= cv['contact_volume_min'] && scores['velocity'].to_f >= cv['velocity_min']
        rules << rule('review_recommended', 'high_volume_and_velocity',
                      'contact_volume' => condition(scores['contact_volume'], cv['contact_volume_min']),
                      'velocity' => condition(scores['velocity'], cv['velocity_min']))
      end

      watch     = @params['watch']
      watch_min = watch['any_subscore_min']
      # Only allowlisted dimensions can raise a watch; unknown/new dimensions are
      # ignored until the policy explicitly adds them (with a version bump).
      Array(watch['dimensions']).each do |dimension|
        next unless scores.key?(dimension)

        score = scores[dimension].to_f
        rules << rule('watch', "elevated_#{dimension}", dimension => condition(score, watch_min)) if score >= watch_min
      end

      rules
    end

    def rule(tier, name, conditions)
      { 'tier' => tier, 'rule' => name, 'conditions' => conditions }
    end

    # A firing condition surfaced for audit/UI: the observed value and the
    # minimum it had to meet.
    def condition(value, minimum)
      { 'value' => value.to_f, 'minimum' => minimum }
    end

    def highest_tier(matched)
      matched.map { |r| r['tier'] }.max_by { |tier| TIERS.index(tier) || -1 } || 'normal'
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
