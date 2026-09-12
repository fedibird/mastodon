# frozen_string_literal: true

# Explainable risk *evaluation* over a subject's behavioural metrics.
#
# This is deliberately NOT a single risk score and NOT a decision. Per the
# design memo it produces a set of independent, bounded sub-scores, each with the
# reason codes that explain it, and stops there:
#
#   * Evaluation only — it emits sub-scores + reason codes. It does NOT decide,
#     recommend, or enforce anything (no action/recommendation/decision output).
#     Mapping evaluation to a decision is a separate, later layer.
#   * Read-only — it computes from Moderation::BehavioralMetricsService (itself
#     read-only) and writes nothing.
#   * Versioned & auditable — POLICY_VERSION identifies the parameter set, and
#     every non-zero contribution carries a reason code with the observed value
#     and window, so a sub-score can always be explained.
#
# The thresholds/weights in DEFAULT_PARAMS are INITIAL and UNCALIBRATED. They are
# explicit and injectable so they can be tuned from Moderation::MetricsDistributionService
# cohort data before any of this is ever wired to a decision. Because a caller can
# inject different params, the output carries both +policy_version+ (which becomes
# "custom" for non-default params unless an explicit version is supplied) and a
# +params_digest+ (a canonical hash of the effective params), so any evaluation is
# reproducible/auditable. Reason codes carry value + threshold + weight + window so
# a sub-score's contributions can be fully reconstructed from the output.
#
# Guardrails encoded here (see the design memo):
#   * A single block/mute never contributes — the rejection sub-score requires
#     multiple INDEPENDENT responders.
#   * Follow-import risk is DEFERRED (always scores 0): the only import signal we
#     have, unresolved_target_ratio, means "did not resolve to a known Account at
#     import time" — NOT "no known relationship with the actor". Using it as an
#     unknown/external-list proxy conflates those, so follow-import scoring waits
#     for relationship-aware features (true unknown_target_ratio, migration_known_follow,
#     existing_relationship).
#   * A "linked" responder is a strong temporal association, not causal proof.
#   * Unobserved remote signals are never scored as absence of behaviour.
module Moderation
  class RiskEvaluationService
    POLICY_VERSION = 'risk-eval-v0-2026-09-12'

    # CALIBRATION TODO: the windows overlap (e.g. 24h ⊂ 7d), so the same
    # underlying event can contribute to more than one reason code within a
    # sub-score (e.g. reports_received_24h and reports_received_7d), and signals
    # across dimensions can be correlated. This double/overlapping contribution is
    # accepted for now because the evaluation is UNCALIBRATED and not wired to any
    # decision. When calibrating against real cohorts, review correlated signals,
    # overlapping windows, and duplicate contribution before assigning meaning to
    # the absolute sub-score magnitudes.
    DEFAULT_PARAMS = {
      'contact_volume' => {
        'unique_targets_24h' => { 'threshold' => 200, 'weight' => 0.5 },
        'unique_targets_7d'  => { 'threshold' => 500, 'weight' => 0.3 },
        'contacts_total_24h' => { 'threshold' => 500, 'weight' => 0.3 },
      },
      'velocity' => {
        'unique_targets_1h' => { 'threshold' => 30,  'weight' => 0.6 },
        'unique_targets_6h' => { 'threshold' => 100, 'weight' => 0.4 },
      },
      'rejection' => {
        # Requires MULTIPLE independent responders — never fires on a single one.
        'unique_negative_responders_24h' => { 'threshold' => 5, 'weight' => 0.5 },
        'linked_negative_responders_24h' => { 'threshold' => 5, 'weight' => 0.3 },
        'negative_response_rate_24h'     => { 'threshold' => 0.2, 'weight' => 0.3, 'min_unique_targets' => 10 },
      },
      'report' => {
        'reports_received_24h' => { 'threshold' => 1, 'weight' => 0.4 },
        'reports_received_7d'  => { 'threshold' => 3, 'weight' => 0.4 },
      },
      # NOTE: no 'follow_import' params — that sub-score is intentionally deferred
      # (see follow_import below and the class comment).
      'repeat_behavior' => {
        'new_targets_after_first_negative_signal_24h' => { 'threshold' => 50, 'weight' => 0.6 },
        'follows_after_first_negative_signal_24h'     => { 'threshold' => 50, 'weight' => 0.4 },
      },
    }.freeze

    def initialize(metrics_service: Moderation::BehavioralMetricsService.new, params: DEFAULT_PARAMS, policy_version: nil)
      @metrics_service = metrics_service
      @params          = params
      # Custom params must not masquerade as the default policy version.
      @policy_version  = policy_version || (params == DEFAULT_PARAMS ? POLICY_VERSION : 'custom')
      @params_digest   = digest(@params)
    end

    def call(subject_or_account, now: Time.now.utc)
      metrics = @metrics_service.call(subject_or_account, now: now)

      {
        'policy_version' => @policy_version,
        'params_digest'  => @params_digest,
        'subject_id'     => metrics['subject_id'],
        'generated_at'   => now.iso8601,
        'subscores'      => {
          'contact_volume'  => contact_volume(metrics),
          'velocity'        => velocity(metrics),
          'rejection'       => rejection(metrics),
          'report'          => report(metrics),
          'follow_import'   => follow_import(metrics),
          'repeat_behavior' => repeat_behavior(metrics),
        },
      }
    end

    private

    def window(metrics, name)
      metrics.dig('windows', name) || {}
    end

    def contact_volume(metrics)
      params = @params['contact_volume']
      build([
        threshold_signal('high_unique_targets_24h', window(metrics, '24h')['unique_targets'], params['unique_targets_24h'], '24h'),
        threshold_signal('high_unique_targets_7d', window(metrics, '7d')['unique_targets'], params['unique_targets_7d'], '7d'),
        threshold_signal('high_contacts_24h', window(metrics, '24h')['contacts_total'], params['contacts_total_24h'], '24h'),
      ])
    end

    def velocity(metrics)
      params = @params['velocity']
      build([
        threshold_signal('high_unique_targets_1h', window(metrics, '1h')['unique_targets'], params['unique_targets_1h'], '1h'),
        threshold_signal('high_unique_targets_6h', window(metrics, '6h')['unique_targets'], params['unique_targets_6h'], '6h'),
      ])
    end

    def rejection(metrics)
      params = @params['rejection']
      data   = window(metrics, '24h')

      signals = [
        threshold_signal('multiple_independent_rejectors', data['unique_negative_responders'], params['unique_negative_responders_24h'], '24h'),
        threshold_signal('linked_independent_rejectors', data['linked_negative_responders'], params['linked_negative_responders_24h'], '24h'),
      ]

      rate_cfg = params['negative_response_rate_24h']
      if data['unique_targets'].to_i >= rate_cfg['min_unique_targets'].to_i && data['negative_response_rate'].to_f >= rate_cfg['threshold']
        # This signal has an extra firing condition beyond the threshold (a
        # minimum contact sample), so record the sample-size condition as reason
        # metadata for auditability/reproducibility.
        signals << reason('elevated_negative_response_rate', data['negative_response_rate'], rate_cfg['weight'], '24h',
                          threshold: rate_cfg['threshold'],
                          metadata: { 'observed_unique_targets' => data['unique_targets'].to_i, 'min_unique_targets' => rate_cfg['min_unique_targets'].to_i })
      end

      build(signals)
    end

    def report(metrics)
      params = @params['report']
      build([
        threshold_signal('reports_received_24h', window(metrics, '24h')['reports_received'], params['reports_received_24h'], '24h'),
        threshold_signal('multiple_reports_7d', window(metrics, '7d')['reports_received'], params['reports_received_7d'], '7d'),
      ])
    end

    # Deferred: the only available import signal (unresolved_target_ratio) means
    # "did not resolve to a known Account at import time", not "no known
    # relationship with the actor", so it must not be used as an unknown /
    # external-list risk proxy. This sub-score stays 0 until relationship-aware
    # features exist. The dimension is kept in the output for shape stability.
    def follow_import(_metrics)
      {
        'score'          => 0.0,
        'reason_codes'   => [],
        'deferred'       => true,
        'deferred_reason' => 'relationship_aware_features_not_yet_available',
      }
    end

    def repeat_behavior(metrics)
      params = @params['repeat_behavior']
      data   = window(metrics, '24h')
      build([
        threshold_signal('continuation_after_rejection', data['new_targets_after_first_negative_signal'], params['new_targets_after_first_negative_signal_24h'], '24h'),
        threshold_signal('follows_after_rejection', data['follows_after_first_negative_signal'], params['follows_after_first_negative_signal_24h'], '24h'),
      ])
    end

    # A BINARY threshold signal: it either fires (contributing its fixed weight)
    # or not, based on `value >= threshold`. It is NOT continuous graded scoring —
    # the contribution does not scale with how far the value exceeds the
    # threshold. (If calibration later warrants continuous scoring, revisit this.)
    def threshold_signal(code, value, config, window_name)
      return nil if value.nil? || config.nil? || value < config['threshold']

      reason(code, value, config['weight'], window_name, threshold: config['threshold'])
    end

    # +metadata+ records any additional firing conditions (beyond the primary
    # threshold) so a reason code alone explains why the signal fired. Any future
    # signal with extra firing conditions should record them here too.
    def reason(code, value, weight, window_name = nil, threshold: nil, metadata: {})
      { code: code, value: value, weight: weight, window: window_name, threshold: threshold, metadata: metadata }
    end

    # Sub-score = sum of fired weights, capped at 1.0. Every fired signal is
    # surfaced as a reason code carrying value + threshold + weight + window, so
    # the sub-score's contributions can be fully reconstructed from the output.
    def build(signals)
      fired = signals.compact
      score = [fired.sum { |signal| signal[:weight] }, 1.0].min

      {
        'score'        => score,
        'reason_codes' => fired.map do |signal|
          {
            'code'      => signal[:code],
            'value'     => signal[:value],
            'threshold' => signal[:threshold],
            'weight'    => signal[:weight],
            'window'    => signal[:window],
          }.compact.merge(signal[:metadata] || {})
        end,
      }
    end

    # Canonical (recursively key-sorted) SHA256 of the effective params, so a
    # given threshold/weight set is identifiable regardless of key order.
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
