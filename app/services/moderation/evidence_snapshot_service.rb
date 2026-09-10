# frozen_string_literal: true

# Builds a ModerationEvidenceSnapshot for a subject over a time window from the
# recorded ledger (interaction + rejection events).
#
# The key artifact is the *linked* negative target set: accounts this subject
# contacted that later returned a negative signal, with a preceding-contact
# link (via +preceding_interaction_event_id+) inside the association window.
# That is a strong temporal association, not proof the rejection was caused
# by that contact.
#
# Same-window overlap without a preceding-contact link is stored separately
# as a weaker correlation and is never written to
# +linked_negative_target_subject_ids+.
#
# Recording/summarising only — no scoring or thresholds.
#
# Inbound ActivityPub coverage: mentions, replies, follows, follow rejects,
# favourites, reactions, blocks, reports, references, and quotes arriving over
# federation are now observed at their record-creation sites. Every modeled
# inbound type is hooked, but coverage is reported as 'partial' because one
# hooked shape (bare-follow-request-URI Reject) can still lose an event under a
# rare double recorder failure. See +fingerprint['coverage']+ for the
# per-event-type map and +known_inbound_recording_gaps+.
module Moderation
  class EvidenceSnapshotService
    SCHEMA_VERSION = 6
    DEFAULT_WINDOW = 30.days

    # Cap the persisted id sets so a pathological subject can't create an
    # unbounded fingerprint.
    MAX_FINGERPRINT_IDS = 1_000

    REJECTION_TYPES = %w(block follow_reject remove_follower report mute mute_notifications).freeze

    # Every modeled inbound event type now has a record-creation-site hook
    # (deferred_inbound_event_types is empty), but "all types hooked" is NOT the
    # same as "coverage is complete/reliable". A rare double recorder failure can
    # still cause a *permanent* ledger miss for one shape (see
    # known_inbound_recording_gaps), so inbound_activitypub stays 'partial' and
    # complete_for_remote_subjects stays false: downstream analysis must not read
    # low/zero counts as absence of behaviour while any known gap remains.
    #
    #   * observed_inbound_event_types    — every modeled type has a hook.
    #   * deferred_inbound_event_types    — types with no hook at all (none left).
    #   * known_inbound_recording_gaps    — hooked types that can still lose an
    #                                       event under the stated failure condition.
    #
    # The remaining gap is the bare-follow-request-URI Reject shape. reject!
    # destroys the FollowRequest (whose URI is an opaque payload id that does not
    # encode the requester), so an ordinary recorder-only failure is now repaired
    # on re-delivery by correlating the follow-request URI to the outbound follow
    # interaction recorded at request time (source_event_key activitypub_follow:<uri>).
    # The event is lost only when BOTH that outbound follow interaction and the
    # inbound reject failed to record, because then no correlation anchor persists.
    # The embedded-Follow Reject shape repairs directly from @object['actor']. A
    # Reject of an already-established follow is intentionally modeled as an
    # unfollow, not a follow_reject.
    INBOUND_ACTIVITYPUB_COVERAGE = {
      'inbound_activitypub' => 'partial',
      'complete_for_remote_subjects' => false,
      'observed_inbound_event_types' => %w(follow follow_reject favourite reaction block report reference mention reply quote).freeze,
      'deferred_inbound_event_types' => [].freeze,
      'known_inbound_recording_gaps' => [
        {
          'event_type' => 'follow_reject',
          'shape' => 'bare_follow_request_uri',
          'condition' => 'double_recorder_failure',
          'repairable' => false,
          'reason' => 'An ordinary recorder-only failure is repaired on re-delivery by correlating the follow-request URI to the outbound follow interaction (activitypub_follow:<uri>). The event is lost only when both the outbound follow interaction and the inbound reject failed to record, leaving no correlation anchor.',
        }.freeze,
      ].freeze,
    }.freeze

    def call(subject_or_account, window: DEFAULT_WINDOW, now: Time.now.utc)
      subject = ModerationSubject.for_account!(subject_or_account, observed_at: now)

      window_start = window.nil? ? nil : now - window
      window_end   = now

      interactions = interactions_scope(subject, window_start, window_end)
      rejections   = rejections_scope(subject, window_start, window_end)

      # Counterpart FKs may be NULL after #31 SET NULL expiry. Never treat a
      # missing id as a contact/target, and never persist nil into fingerprints.
      contacted_ids      = interactions.distinct.pluck(:target_subject_id).compact
      rejections_by_type = rejections.group(:event_type).count
      linked_ids, correlated_ids = classify_negative_targets(rejections, contacted_ids)

      summary = {
        'interactions_count'               => interactions.count,
        'unique_contacts'                  => contacted_ids.size,
        'negative_responders'              => rejections.distinct.count(:rejector_subject_id),
        'linked_negative_target_count'     => linked_ids.size,
        'correlated_negative_target_count' => correlated_ids.size,
        'blocks_received'                  => rejections_by_type['block'].to_i,
        'follow_rejects_received'          => rejections_by_type['follow_reject'].to_i,
        'removed_as_follower'              => rejections_by_type['remove_follower'].to_i,
        'reports_received'                 => rejections_by_type['report'].to_i,
        'mutes_received'                   => rejections_by_type['mute'].to_i + rejections_by_type['mute_notifications'].to_i,
      }

      fingerprint = {
        'linked_negative_target_subject_ids'     => linked_ids.first(MAX_FINGERPRINT_IDS),
        'correlated_negative_target_subject_ids' => correlated_ids.first(MAX_FINGERPRINT_IDS),
        'contacted_target_count'                 => contacted_ids.size,
        'coverage'                               => INBOUND_ACTIVITYPUB_COVERAGE,
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

    # Linked: preceding-contact link (strong temporal association).
    # Correlated: same-window subject-id overlap without that link.
    def classify_negative_targets(rejections, contacted_ids)
      contacted = contacted_ids.to_set
      linked = Set.new
      correlated = Set.new

      rejections.includes(:preceding_interaction_event).find_each do |rejection|
        rejector_id = rejection.rejector_subject_id
        next if rejector_id.nil?
        next unless contacted.include?(rejector_id)

        if Moderation::PrecedingContactLink.strong_association?(rejection.preceding_interaction_event, rejection)
          linked << rejector_id
        else
          correlated << rejector_id
        end
      end

      # A rejector with any preceding-contact link is not also reported as a
      # weak correlation — the fingerprint must not imply both.
      correlated.subtract(linked)

      [linked.to_a, correlated.to_a]
    end
  end
end
