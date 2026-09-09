# frozen_string_literal: true

# Records a moderator action into the ledger and captures an evidence snapshot
# at the same time. This is the entry point moderation flows call.
#
# The class-level helper is failure-tolerant: a recording error is logged and
# returns nil, so it never breaks the moderation action itself.
module Moderation
  class ActionRecorder
    class << self
      def record(**options)
        new.record(**options)
      rescue StandardError => e
        Rails.logger.warn("[Moderation::ActionRecorder] failed to record moderation action: #{e.class}: #{e.message}")
        nil
      end
    end

    def record(account:, action_type:, moderator: nil, reason_code: nil, window: Moderation::EvidenceSnapshotService::DEFAULT_WINDOW, performed_at: nil, metadata: {})
      performed_at ||= Time.now.utc
      subject = ModerationSubject.for_account!(account, observed_at: performed_at)

      snapshot = Moderation::EvidenceSnapshotService.new.call(subject, window: window, now: performed_at)

      ModerationAction.create!(
        subject: subject,
        action_type: action_type,
        performed_at: performed_at,
        moderator_account_id: moderator&.id,
        reason_code: reason_code,
        evidence_snapshot: snapshot,
        metadata: metadata || {}
      )
    end
  end
end
