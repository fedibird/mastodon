# frozen_string_literal: true

# Builds a ModerationEvidenceSnapshot for a subject over a time window from the
# recorded ledger (interaction + rejection events).
#
# The key artifact is the negative target set: the accounts this subject
# contacted that returned a negative signal (block/mute/reject/remove/report).
# Recording/summarising only — no scoring or thresholds.
module Moderation
  class EvidenceSnapshotService
    SCHEMA_VERSION = 1
    DEFAULT_WINDOW = 30.days

    # Cap the persisted id sets so a pathological subject can't create an
    # unbounded fingerprint.
    MAX_FINGERPRINT_IDS = 1_000

    REJECTION_TYPES = %w(block follow_reject remove_follower report mute mute_notifications).freeze

    def call(subject_or_account, window: DEFAULT_WINDOW, now: Time.now.utc)
      subject = ModerationSubject.for_account!(subject_or_account, observed_at: now)

      window_start = window.nil? ? nil : now - window
      window_end   = now

      interactions = interactions_scope(subject, window_start, window_end)
      rejections   = rejections_scope(subject, window_start, window_end)

      contacted_ids       = interactions.distinct.pluck(:target_subject_id)
      rejections_by_type  = rejections.group(:event_type).count
      negative_target_ids = rejections.where(rejector_subject_id: contacted_ids).distinct.pluck(:rejector_subject_id)

      summary = {
        'interactions_count'      => interactions.count,
        'unique_contacts'         => contacted_ids.size,
        'negative_responders'     => rejections.distinct.count(:rejector_subject_id),
        'negative_target_count'   => negative_target_ids.size,
        'blocks_received'         => rejections_by_type['block'].to_i,
        'follow_rejects_received' => rejections_by_type['follow_reject'].to_i,
        'removed_as_follower'     => rejections_by_type['remove_follower'].to_i,
        'reports_received'        => rejections_by_type['report'].to_i,
        'mutes_received'          => rejections_by_type['mute'].to_i + rejections_by_type['mute_notifications'].to_i,
      }

      fingerprint = {
        'negative_target_subject_ids' => negative_target_ids.first(MAX_FINGERPRINT_IDS),
        'contacted_target_count'      => contacted_ids.size,
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
  end
end
