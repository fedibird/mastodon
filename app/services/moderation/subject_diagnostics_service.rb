# frozen_string_literal: true

# Operator-facing, read-only explanation of a subject's current observation
# quality, evaluation, and proposed follow-gate friction.
#
# Pipeline (composed, not reimplemented):
#
#   raw observations
#     → qualification / linkage quality
#     → BehavioralMetricsService
#     → RiskEvaluationService
#     → AdaptiveFollowGateDecisionService
#
# This service writes nothing: no ModerationSubject creation, no evidence
# snapshot, no moderation action, and no follow-gate enforcement. Follow
# Import unresolved ratios and campaign recurrence observations are
# reported as observational context only.
#
# Absence of observed negatives is not treated as evidence of absence.
# Output is structured metadata (ids, types, counts, timestamps, rates,
# reason codes) — never post/DM/profile/report/ActivityPub bodies.
module Moderation
  class SubjectDiagnosticsService
    CONTACT_WINDOWS = %w(1h 24h 7d).freeze

    def initialize(metrics_service: BehavioralMetricsService.new, evaluator: nil, gate: nil, negative_signal_query: NegativeSignalQuery.new, recurrence_observer: FollowImportRecurrenceObservationService.new)
      @metrics_service = metrics_service
      @evaluator = evaluator
      @gate = gate
      @negative_signal_query = negative_signal_query
      @recurrence_observer = recurrence_observer
    end

    # +context+ is the optional follow-attempt context forwarded unchanged to
    # AdaptiveFollowGateDecisionService (mechanism / target_locality /
    # target_locked / relationship_context). Mechanism never raises risk.
    def call(subject_or_account, context: {}, now: Time.now.utc)
      subject     = resolve_subject(subject_or_account)
      metrics     = @metrics_service.call(subject_or_account, now: now)
      evaluation  = evaluator_for(metrics).call(subject_or_account, now: now)
      decision    = gate_for(evaluation).call(subject_or_account, context: context, now: now)
      window_24h  = metrics.dig('windows', '24h') || {}
      follow_import = metrics['follow_import_context'] || {}
      negatives = @negative_signal_query.summarize(subject, window_start: now - 24.hours, window_end: now)

      unique_responders = window_24h['unique_negative_responders'].to_i
      linked_responders = window_24h['linked_negative_responders'].to_i
      qualified_unique_responders = window_24h['qualified_unique_negative_responders'].to_i
      qualified_response_rate = window_24h['qualified_negative_response_rate'].to_f
      raw_events        = negatives['raw_events']
      qualified_events  = negatives['qualified_events']
      qualification_rate = ratio(qualified_events, raw_events)
      link_rate          = ratio(linked_responders, unique_responders)

      {
        'subject_id'   => metrics['subject_id'],
        'account_id'   => metrics['account_id'],
        'generated_at' => now.iso8601,
        'contacts'     => contact_windows(metrics),
        'negative_signals' => {
          '24h' => negatives.merge(
            'unique_responders' => unique_responders,
            'linked_responders' => linked_responders,
            'qualified_unique_responders' => qualified_unique_responders,
            'qualified_response_rate' => qualified_response_rate,
            'qualification_rate' => qualification_rate,
            'link_rate' => link_rate
          ),
        },
        'continuation' => {
          'first_qualified_negative_at' => window_24h['first_negative_signal_at'],
          'new_targets_after_first_negative_signal_24h' => window_24h['new_targets_after_first_negative_signal'].to_i,
          'follows_after_first_negative_signal_24h' => window_24h['follows_after_first_negative_signal'].to_i,
        },
        'reports' => {
          '24h' => window_24h['reports_received'].to_i,
          '7d' => (metrics.dig('windows', '7d') || {})['reports_received'].to_i,
        },
        'follow_import' => follow_import_block(follow_import, subject_or_account, now),
        'observation_quality' => {
          'negative_qualification_rate' => qualification_rate,
          'contact_link_rate' => link_rate,
          'inbound_activitypub_coverage' => EvidenceSnapshotService::INBOUND_ACTIVITYPUB_COVERAGE['inbound_activitypub'],
          'complete_for_remote_subjects' => EvidenceSnapshotService::INBOUND_ACTIVITYPUB_COVERAGE['complete_for_remote_subjects'],
          'notes' => observation_quality_notes,
        },
        'evaluation' => evaluation,
        'follow_gate' => decision,
      }
    end

    private

    # Read-only resolution: never ModerationSubject.for_account!.
    def resolve_subject(subject_or_account)
      return subject_or_account if subject_or_account.is_a?(ModerationSubject)
      return if subject_or_account.nil?

      ModerationSubject.find_by(account_id: subject_or_account.id)
    end

    def evaluator_for(metrics)
      @evaluator || RiskEvaluationService.new(metrics_service: CachedCall.new(metrics))
    end

    def gate_for(evaluation)
      @gate || AdaptiveFollowGateDecisionService.new(evaluator: CachedCall.new(evaluation))
    end

    def contact_windows(metrics)
      CONTACT_WINDOWS.index_with do |name|
        window = metrics.dig('windows', name) || {}
        {
          'total' => window['contacts_total'].to_i,
          'unique_targets' => window['unique_targets'].to_i,
        }
      end
    end

    def follow_import_block(follow_import, subject_or_account, now)
      {
        'batch_count' => follow_import['batch_count'].to_i,
        'target_total' => follow_import['target_total'].to_i,
        'resolved_target_count' => follow_import['resolved_target_total'].to_i,
        'unresolved_target_count' => follow_import['unresolved_target_total'].to_i,
        'unresolved_target_ratio' => follow_import['unresolved_target_ratio'].to_f,
        'recurrence_observation' => @recurrence_observer.call(subject_or_account, now: now),
      }
    end

    def observation_quality_notes
      [
        'absence of observed negatives is not evidence of absence',
        'remote negative signals may be incompletely observed',
        'inbound ActivityPub coverage is partial; a hooked follow_reject shape can still be lost under double recorder failure',
        'follow-import unresolved_target_ratio is observational and is not used as an abuse signal',
      ] + FollowImportRecurrenceObservationService::NOTES
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.nil? || denominator.to_i.zero?

      numerator.to_f / denominator
    end

    # Replays a previously computed Hash so evaluation and the follow-gate
    # decision share one metrics/evaluation pass instead of re-querying.
    class CachedCall
      def initialize(result)
        @result = result
      end

      def call(*)
        @result
      end
    end
    private_constant :CachedCall
  end
end
