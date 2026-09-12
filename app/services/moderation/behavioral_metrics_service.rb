# frozen_string_literal: true

# Computes analysis-only behavioural metrics for a moderation subject from the
# recorded ledger (interaction + rejection events, follow-import batches).
#
# This is the Analysis phase's read layer. It is strictly observational:
#
#   * READ-ONLY — it never writes to the database (it does not create or update
#     ModerationSubject rows), so it is safe to call from dashboards/queries.
#   * No scoring, thresholds, risk labels, recommendations, or enforcement. It
#     returns plain counts/rates only; interpretation belongs to later phases.
#   * Metrics are mechanism-independent: they describe how widely / how fast a
#     subject contacted others and how many independent recipients returned an
#     explicit negative signal — never the meaning of any content.
#
# Rates return raw floats (no rounding); presentation layers round for display.
#
# Cohort discipline for anything named a *rate*: numerator and denominator are
# drawn from the SAME in-window contact cohort, so a rate can never exceed 1 and
# an out-of-window contact paired with an in-window rejection cannot inflate it.
# Raw event-window counts (contacts, follows, rejections, unique responders) are
# kept separately and are unaffected.
#
# A "linked" negative responder is a strong temporal association (a preceding
# contact within the association window), NOT proof the contact caused the
# rejection — matching Moderation::PrecedingContactLink and the evidence snapshot.
module Moderation
  class BehavioralMetricsService
    # Ordered so the output reads shortest-to-longest.
    DEFAULT_WINDOWS = {
      '1h'  => 1.hour,
      '6h'  => 6.hours,
      '24h' => 24.hours,
      '7d'  => 7.days,
      '30d' => 30.days,
    }.freeze

    REJECTION_TYPES = %w(block follow_reject remove_follower report mute mute_notifications).freeze
    INTERACTION_TYPES = %w(follow mention reply quote reference reaction favourite follow_import).freeze

    def call(subject_or_account, now: Time.now.utc, windows: DEFAULT_WINDOWS)
      subject = resolve_subject(subject_or_account)

      {
        'subject_id'            => subject&.id,
        'account_id'            => subject&.account_id,
        'generated_at'          => now.iso8601,
        'windows'               => windows.transform_values { |duration| window_metrics(subject, now - duration, now) },
        'lifetime'              => window_metrics(subject, nil, now),
        'follow_import_context' => follow_import_context(subject),
      }
    end

    private

    # Read-only resolution: accept a ModerationSubject, or find the one bound to
    # an Account. Never create or touch a row (unlike ModerationSubject.for_account!).
    def resolve_subject(subject_or_account)
      return subject_or_account if subject_or_account.is_a?(ModerationSubject)
      return if subject_or_account.nil?

      ModerationSubject.find_by(account_id: subject_or_account.id)
    end

    def window_metrics(subject, window_start, window_end)
      base = empty_window(window_start, window_end)
      return base if subject.nil?

      interactions = interactions_scope(subject, window_start, window_end)
      rejections   = rejections_scope(subject, window_start, window_end)

      interactions_by_type = INTERACTION_TYPES.index_with { |type| interactions.where(event_type: type).count }
      contacts_total       = interactions.count
      contacted_ids        = distinct_ids(interactions, :target_subject_id)
      unique_targets       = contacted_ids.size
      followed_ids         = distinct_ids(interactions.where(event_type: :follow), :target_subject_id)
      follows              = interactions_by_type['follow']

      rejections_by_type = REJECTION_TYPES.index_with { |type| rejections.where(event_type: type).count }
      rejections_total   = rejections.count
      unique_responders  = distinct_ids(rejections, :rejector_subject_id).size
      mutes_received     = rejections_by_type['mute'] + rejections_by_type['mute_notifications']

      # Cohort-aligned: rejectors that were also contacted in this window.
      linked_set, correlated_set = classify_negative_responders(rejections, contacted_ids)
      responder_cohort           = linked_set | correlated_set

      # Cohort-aligned: follow-rejects only from targets this window actually followed.
      follow_reject_cohort = distinct_ids(rejections.where(event_type: :follow_reject), :rejector_subject_id) & followed_ids

      first_negative_at = rejections.minimum(:occurred_at)
      continuation      = continuation_after(subject, interactions, first_negative_at)

      base.merge(
        'contacts_total'                          => contacts_total,
        'unique_targets'                          => unique_targets,
        'follows'                                 => follows,
        'interactions_by_type'                    => interactions_by_type,
        'rejections_received_total'               => rejections_total,
        'rejections_by_type'                      => rejections_by_type,
        'blocks_received'                         => rejections_by_type['block'],
        'follow_rejects_received'                 => rejections_by_type['follow_reject'],
        'remove_follower_received'                => rejections_by_type['remove_follower'],
        'reports_received'                        => rejections_by_type['report'],
        'mutes_received'                          => mutes_received,
        'unique_negative_responders'              => unique_responders,
        'linked_negative_responders'              => linked_set.size,
        'correlated_negative_responders'          => correlated_set.size,
        # Rates: numerator and denominator share the in-window contact cohort.
        'negative_response_rate'                  => ratio(responder_cohort.size, unique_targets),
        'linked_negative_rate'                    => ratio(linked_set.size, unique_targets),
        'follow_reject_rate'                      => ratio(follow_reject_cohort.size, followed_ids.size),
        'first_negative_signal_at'                => first_negative_at&.iso8601,
        'new_targets_after_first_negative_signal' => continuation[:new_targets],
        'follows_after_first_negative_signal'     => continuation[:follows]
      )
    end

    def empty_window(window_start, window_end)
      {
        'window_start'                            => window_start&.iso8601,
        'window_end'                              => window_end&.iso8601,
        'contacts_total'                          => 0,
        'unique_targets'                          => 0,
        'follows'                                 => 0,
        'interactions_by_type'                    => INTERACTION_TYPES.index_with { 0 },
        'rejections_received_total'               => 0,
        'rejections_by_type'                      => REJECTION_TYPES.index_with { 0 },
        'blocks_received'                         => 0,
        'follow_rejects_received'                 => 0,
        'remove_follower_received'                => 0,
        'reports_received'                        => 0,
        'mutes_received'                          => 0,
        'unique_negative_responders'              => 0,
        'linked_negative_responders'              => 0,
        'correlated_negative_responders'          => 0,
        'negative_response_rate'                  => 0.0,
        'linked_negative_rate'                    => 0.0,
        'follow_reject_rate'                      => 0.0,
        'first_negative_signal_at'                => nil,
        'new_targets_after_first_negative_signal' => 0,
        'follows_after_first_negative_signal'     => 0,
      }
    end

    def interactions_scope(subject, window_start, window_end)
      scope = ModerationInteractionEvent.where(actor_subject_id: subject.id)
      scope = scope.where(occurred_at: window_start..window_end) if window_start
      scope = scope.where('occurred_at <= ?', window_end) if window_start.nil? && window_end
      scope
    end

    def rejections_scope(subject, window_start, window_end)
      scope = ModerationRejectionEvent.where(rejected_subject_id: subject.id)
      scope = scope.where(occurred_at: window_start..window_end) if window_start
      scope = scope.where('occurred_at <= ?', window_end) if window_start.nil? && window_end
      scope
    end

    def distinct_ids(scope, column)
      scope.where.not(column => nil).distinct.pluck(column).to_set
    end

    # Linked: rejector was contacted first with a preceding-contact link (strong
    # temporal association). Correlated: rejector was contacted in this window
    # but without that link. A rejector counted as linked is never also correlated.
    # Both sets are restricted to rejectors that were contacted in-window, so the
    # cohort-aligned rates built from them cannot exceed 1.
    def classify_negative_responders(rejections, contacted_ids)
      linked = Set.new
      correlated = Set.new

      rejections.includes(:preceding_interaction_event).find_each do |rejection|
        rejector_id = rejection.rejector_subject_id
        next if rejector_id.nil?
        next unless contacted_ids.include?(rejector_id)

        if Moderation::PrecedingContactLink.strong_association?(rejection.preceding_interaction_event, rejection)
          linked << rejector_id
        else
          correlated << rejector_id
        end
      end

      correlated.subtract(linked)
      [linked, correlated]
    end

    # Genuinely new targets contacted after the first negative signal in scope: a
    # target contacted after the signal AND with no actor->target contact at or
    # before that signal in the subject's whole history (re-contacting a target
    # already contacted before the signal does not count). Plus follows sent
    # after the signal. Zero when no negative signal was observed in scope.
    def continuation_after(subject, interactions, first_negative_at)
      return { new_targets: 0, follows: 0 } if first_negative_at.nil?

      after         = interactions.where('occurred_at > ?', first_negative_at)
      candidate_ids = distinct_ids(after, :target_subject_id)

      new_targets =
        if candidate_ids.empty?
          0
        else
          previously_contacted = ModerationInteractionEvent
                                  .where(actor_subject_id: subject.id, target_subject_id: candidate_ids.to_a)
                                  .where('occurred_at <= ?', first_negative_at)
                                  .distinct.pluck(:target_subject_id)
                                  .to_set
          (candidate_ids - previously_contacted).size
        end

      { new_targets: new_targets, follows: after.where(event_type: :follow).count }
    end

    def follow_import_context(subject)
      empty = {
        'batch_count'                       => 0,
        'target_total'                      => 0,
        'resolved_target_total'             => 0,
        'unresolved_target_total'           => 0,
        # NOTE: unresolved == "did not resolve to a known Account at import time".
        # This is NOT the design's "unknown target" (no confirmable prior
        # relationship with the actor); that true unknown_target_ratio is
        # deferred to the relationship-aware analysis phase.
        'unresolved_target_ratio'           => 0.0,
        'prior_relationship_known_targets'  => 0,
        'latest_import_at'                  => nil,
        'min_account_age_seconds_at_import' => nil,
        'migration_evidence'                => FollowImportBatch.migration_evidences.keys.index_with { 0 },
      }
      return empty if subject.nil?

      batches = FollowImportBatch.where(subject_id: subject.id)
      return empty if batches.none?

      target_total     = batches.sum(:target_count)
      unresolved_total = batches.sum(:unresolved_target_count)

      {
        'batch_count'                       => batches.count,
        'target_total'                      => target_total,
        'resolved_target_total'             => batches.sum(:resolved_target_count),
        'unresolved_target_total'           => unresolved_total,
        'unresolved_target_ratio'           => ratio(unresolved_total, target_total),
        'prior_relationship_known_targets'  => prior_relationship_known_targets(batches),
        'latest_import_at'                  => batches.maximum(:imported_at)&.iso8601,
        'min_account_age_seconds_at_import' => batches.where.not(account_age_seconds: nil).minimum(:account_age_seconds),
        'migration_evidence'                => FollowImportBatch.migration_evidences.keys.index_with { |k| batches.where(migration_evidence: k).count },
      }
    end

    # Targets the actor already followed at import time — a known relationship,
    # so far less likely to be an external-list scrape.
    def prior_relationship_known_targets(batches)
      FollowImportTarget
        .where(batch_id: batches.select(:id))
        .where("prior_relationship_state ->> 'following' = 'true'")
        .count
    end

    # Raw float (no rounding) — presentation layers round for display.
    def ratio(numerator, denominator)
      return 0.0 if denominator.nil? || denominator.zero?

      numerator.to_f / denominator
    end
  end
end
