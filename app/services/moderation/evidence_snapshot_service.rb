# frozen_string_literal: true

# Builds a ModerationEvidenceSnapshot for a subject over a time window from the
# recorded ledger (interaction + rejection events).
#
# The key artifact is the negative target set: accounts this subject contacted
# that then returned a negative signal *after* that contact, within the causal
# window, preferably linked via +preceding_interaction_event_id+.
#
# Same-window overlap without a proven A→B then B→A order is stored separately
# as a weaker correlation and is never written to +negative_target_subject_ids+.
#
# Recording/summarising only — no scoring or thresholds.
#
# Coverage limitation: inbound ActivityPub-only mentions, replies, follows,
# favourites, reactions, and blocks are not yet observed. A remote subject can
# therefore accumulate local blocks/reports while the triggering remote
# contacts are missing. Snapshots (and future scores) for remote actors are
# incomplete until those paths are covered. See +fingerprint['coverage']+.
module Moderation
  class EvidenceSnapshotService
    SCHEMA_VERSION = 2
    DEFAULT_WINDOW = 30.days

    # Cap the persisted id sets so a pathological subject can't create an
    # unbounded fingerprint.
    MAX_FINGERPRINT_IDS = 1_000

    REJECTION_TYPES = %w(block follow_reject remove_follower report mute mute_notifications).freeze

    # Explicit until inbound ActivityPub interaction paths are wired. Do not
    # treat snapshot counts or future scores as complete for remote actors.
    INBOUND_ACTIVITYPUB_COVERAGE = {
      'inbound_activitypub' => 'deferred',
      'complete_for_remote_subjects' => false,
    }.freeze

    def call(subject_or_account, window: DEFAULT_WINDOW, now: Time.now.utc)
      subject = ModerationSubject.for_account!(subject_or_account, observed_at: now)

      window_start = window.nil? ? nil : now - window
      window_end   = now

      interactions = interactions_scope(subject, window_start, window_end)
      rejections   = rejections_scope(subject, window_start, window_end)

      contacted_ids      = interactions.distinct.pluck(:target_subject_id)
      rejections_by_type = rejections.group(:event_type).count
      strong_ids, weak_ids = classify_negative_targets(rejections, contacted_ids)

      summary = {
        'interactions_count'              => interactions.count,
        'unique_contacts'                 => contacted_ids.size,
        'negative_responders'             => rejections.distinct.count(:rejector_subject_id),
        'negative_target_count'           => strong_ids.size,
        'correlated_negative_target_count' => weak_ids.size,
        'blocks_received'                 => rejections_by_type['block'].to_i,
        'follow_rejects_received'         => rejections_by_type['follow_reject'].to_i,
        'removed_as_follower'             => rejections_by_type['remove_follower'].to_i,
        'reports_received'                => rejections_by_type['report'].to_i,
        'mutes_received'                  => rejections_by_type['mute'].to_i + rejections_by_type['mute_notifications'].to_i,
      }

      fingerprint = {
        'negative_target_subject_ids'              => strong_ids.first(MAX_FINGERPRINT_IDS),
        'correlated_negative_target_subject_ids'   => weak_ids.first(MAX_FINGERPRINT_IDS),
        'contacted_target_count'                   => contacted_ids.size,
        'coverage'                                 => INBOUND_ACTIVITYPUB_COVERAGE,
      }

      ModerationEvidenceSnapshot.create!(
        subject: subject,
        window_start: window_start,
        window_end: window_end,
        summary: summary,
        fingerprint: fingerprint,
        schema_version: SCHEMA_VERSION
      )
    end

    private

    def interactions_scope(subject, window_start, window_end)
      scope = ModerationInteractionEvent.where(actor_subject_id: subject.id)
      scope = scope.where(occurred_at: window_start..window_end) if window_start
      scope
    end

    def rejections_scope(subject, window_start, window_end)
      scope = ModerationRejectionEvent.where(rejected_subject_id: subject.id)
      scope = scope.where(occurred_at: window_start..window_end) if window_start
      scope
    end

    # Strong: linked preceding interaction that satisfies causality.
    # Weak: same-window subject-id overlap without a valid causal link.
    def classify_negative_targets(rejections, contacted_ids)
      contacted = contacted_ids.to_set
      strong = Set.new
      weak = Set.new

      rejections.includes(:preceding_interaction_event).find_each do |rejection|
        rejector_id = rejection.rejector_subject_id
        next unless contacted.include?(rejector_id)

        if Moderation::Causality.valid_link?(rejection.preceding_interaction_event, rejection)
          strong << rejector_id
        else
          weak << rejector_id
        end
      end

      # A rejector with any strong link is not also reported as a weak
      # correlation — the fingerprint must not imply both.
      weak.subtract(strong)

      [strong.to_a, weak.to_a]
    end
  end
end
