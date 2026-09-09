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
#
# This phase performs recording only: no scoring, throttling, or enforcement.
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
    def record_interaction(actor:, target:, event_type:, status: nil, source_record: nil, import_batch_id: nil, occurred_at: nil, observed_at: nil, metadata: {})
      observed_at ||= Time.now.utc
      actor_subject  = ModerationSubject.for_account!(actor, observed_at: observed_at)
      target_subject = ModerationSubject.for_account!(target, observed_at: observed_at)

      ModerationInteractionEvent.create!(
        actor_subject: actor_subject,
        target_subject: target_subject,
        event_type: event_type,
        status_id: status&.id,
        source_record_type: source_record&.class&.base_class&.name,
        source_record_id: source_record&.id,
        import_batch_id: import_batch_id,
        occurred_at: occurred_at || observed_at,
        observed_at: observed_at,
        metadata: metadata || {}
      )
    end

    # Record a negative signal (rejector -> rejected). +preceding_interaction+
    # optionally links the contact this rejection responded to.
    def record_rejection(rejector:, rejected:, event_type:, preceding_interaction: nil, occurred_at: nil, observed_at: nil, metadata: {})
      observed_at ||= Time.now.utc
      rejector_subject = ModerationSubject.for_account!(rejector, observed_at: observed_at)
      rejected_subject = ModerationSubject.for_account!(rejected, observed_at: observed_at)

      ModerationRejectionEvent.create!(
        rejector_subject: rejector_subject,
        rejected_subject: rejected_subject,
        event_type: event_type,
        preceding_interaction_event: preceding_interaction,
        occurred_at: occurred_at || observed_at,
        observed_at: observed_at,
        metadata: metadata || {}
      )
    end
  end
end
