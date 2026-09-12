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
      unique_targets       = interactions.distinct.count(:target_subject_id)
      follows              = interactions_by_type['follow']

      rejections_by_type    = REJECTION_TYPES.index_with { |type| rejections.where(event_type: type).count }
      rejections_total      = rejections.count
      unique_responders     = rejections.distinct.count(:rejector_subject_id)
      linked, correlated    = classify_negative_responders(rejections, interactions_actor_target_ids(interactions))
      mutes_received        = rejections_by_type['mute'] + rejections_by_type['mute_notifications']

      first_negative_at     = rejections.minimum(:occurred_at)
      continuation          = continuation_after(interactions, first_negative_at)

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
        'linked_negative_responders'              => linked,
        'correlated_negative_responders'          => correlated,
        'negative_response_rate'                  => ratio(unique_responders, unique_targets),
        'linked_negative_rate'                    => ratio(linked, unique_targets),
        'follow_reject_rate'                      => ratio(rejections_by_type['follow_reject'], follows),
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

    def interactions_actor_target_ids(interactions)
      interactions.distinct.pluck(:target_subject_id).compact.to_set
    end

    # Linked: rejector was contacted first with a preceding-contact link (strong
    # temporal association). Correlated: rejector was contacted in scope but
    # without that link. A rejector counted as linked is never also correlated.
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
      [linked.size, correlated.size]
    end

    # Contacts that continued after the first negative signal in scope: targets
    # whose first in-scope contact happened after the signal, and follows sent
    # after it. Zero when no negative signal was observed in scope.
    def continuation_after(interactions, first_negative_at)
      return { new_targets: 0, follows: 0 } if first_negative_at.nil?

      first_contact_per_target = interactions.where.not(target_subject_id: nil).group(:target_subject_id).minimum(:occurred_at)
      new_targets = first_contact_per_target.count { |_id, at| at && at > first_negative_at }
      follows = interactions.where(event_type: :follow).where('occurred_at > ?', first_negative_at).count

      { new_targets: new_targets, follows: follows }
    end

    def follow_import_context(subject)
      empty = {
        'batch_count'                      => 0,
        'target_total'                     => 0,
        'resolved_target_total'            => 0,
        'unresolved_target_total'          => 0,
        'unknown_target_ratio'             => 0.0,
        'prior_relationship_known_targets' => 0,
        'latest_import_at'                 => nil,
        'min_account_age_seconds_at_import' => nil,
        'migration_evidence'               => FollowImportBatch.migration_evidences.keys.index_with { 0 },
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
        'unknown_target_ratio'              => ratio(unresolved_total, target_total),
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

    def ratio(numerator, denominator)
      return 0.0 if denominator.nil? || denominator.zero?

      (numerator.to_f / denominator).round(4)
    end
  end
end
