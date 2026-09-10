# frozen_string_literal: true

# Records moderation-signal ledger events (interactions and rejections).
#
# This is the single entry point future interaction/rejection hooks should call.
# Design goals (see docs/moderation-signal-design.md, Phase 1):
#
#   * Never break a normal Mastodon operation because recording failed — the
#     class-level helpers swallow and log errors and return +nil+.
#   * Never lose a failure silently — every swallowed error is logged so gaps
#     are observable.
#   * Record only behavioural metadata (who / whom / what / when), never raw
#     post/DM/profile content.
#   * Source-backed observations are idempotent: a stable +source_event_key+
#     plus a unique index prevent duplicate rows when a caller retries or
#     loses a uniqueness race.
#
# This phase performs recording only: no scoring, throttling, or enforcement.
#
# Inbound ActivityPub-only paths (remote mention/reply/follow/follow_reject/
# favourite/reaction/block) are hooked at their record-creation sites, but one
# hooked shape can still lose an event under a rare double recorder failure. See
# Moderation::EvidenceSnapshotService's coverage map (known_inbound_recording_gaps)
# for the residual reliability limitation.
module Moderation
  class EventRecorder
    class << self
      # Failure-tolerant wrappers intended for call sites on hot paths.
      def record_interaction(**options)
        new.record_interaction(**options)
      rescue StandardError => e
        handle_error(:interaction, e)
        nil
      end

      def record_rejection(**options)
        new.record_rejection(**options)
      rescue StandardError => e
        handle_error(:rejection, e)
        nil
      end

      def handle_error(kind, error)
        Rails.logger.warn("[Moderation::EventRecorder] failed to record #{kind} event: #{error.class}: #{error.message}")
        nil
      end
    end

    # Record a contact (actor -> target). +actor+/+target+ may be an Account or
    # an already-resolved ModerationSubject. Raises on failure; prefer the
    # class-level Moderation::EventRecorder.record_interaction at call sites.
    def record_interaction(actor:, target:, event_type:, status: nil, source_record: nil, import_batch_id: nil, occurred_at: nil, observed_at: nil, metadata: {}, source_event_key: nil)
      observed_at ||= Time.now.utc
      actor_subject  = ModerationSubject.for_account!(actor, observed_at: observed_at)
      target_subject = ModerationSubject.for_account!(target, observed_at: observed_at)
      key = source_event_key.presence || self.class.source_event_key_for(source_record, event_type)

      upsert_by_source_key(ModerationInteractionEvent, key) do
        ModerationInteractionEvent.create!(
          actor_subject: actor_subject,
          target_subject: target_subject,
          event_type: event_type,
          status_id: status&.id,
          source_record_type: source_record&.class&.base_class&.name,
          source_record_id: source_record&.id,
          import_batch_id: import_batch_id,
          source_event_key: key,
          occurred_at: occurred_at || observed_at,
          observed_at: observed_at,
          metadata: metadata || {}
        )
      end
    end

    # Record a negative signal (rejector -> rejected). When the caller does
    # not supply a preceding interaction, the nearest earlier contact from
    # rejected → rejector within the association window is linked automatically.
    # The link is a strong temporal association, not a causal proof.
    def record_rejection(rejector:, rejected:, event_type:, preceding_interaction: nil, occurred_at: nil, observed_at: nil, metadata: {}, source_record: nil, source_event_key: nil)
      observed_at ||= Time.now.utc
      occurred_at ||= observed_at
      rejector_subject = ModerationSubject.for_account!(rejector, observed_at: observed_at)
      rejected_subject = ModerationSubject.for_account!(rejected, observed_at: observed_at)
      key = source_event_key.presence || self.class.source_event_key_for(source_record, event_type)

      preceding = resolve_preceding_interaction(
        explicit: preceding_interaction,
        rejected_subject: rejected_subject,
        rejector_subject: rejector_subject,
        occurred_at: occurred_at
      )

      upsert_by_source_key(ModerationRejectionEvent, key) do
        ModerationRejectionEvent.create!(
          rejector_subject: rejector_subject,
          rejected_subject: rejected_subject,
          event_type: event_type,
          preceding_interaction_event: preceding,
          source_event_key: key,
          occurred_at: occurred_at,
          observed_at: observed_at,
          metadata: metadata || {}
        )
      end
    end

    def self.source_event_key_for(source_record, event_type)
      return if source_record.nil? || source_record.id.nil?

      "#{source_record.class.base_class.name}:#{source_record.id}:#{event_type}"
    end

    private

    def resolve_preceding_interaction(explicit:, rejected_subject:, rejector_subject:, occurred_at:)
      if Moderation::PrecedingContactLink.valid_pair?(
        explicit,
        rejected_subject_id: rejected_subject.id,
        rejector_subject_id: rejector_subject.id,
        occurred_at: occurred_at
      )
        return explicit
      end

      Moderation::PrecedingContactLink.find_preceding_interaction(
        rejected_subject: rejected_subject,
        rejector_subject: rejector_subject,
        occurred_at: occurred_at
      )
    end

    def upsert_by_source_key(model, key)
      if key.present?
        existing = model.find_by(source_event_key: key)
        return existing if existing
      end

      yield
    rescue ActiveRecord::RecordNotUnique
      raise if key.blank?

      model.find_by!(source_event_key: key)
    end
  end
end
