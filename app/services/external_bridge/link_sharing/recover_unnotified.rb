# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Outbox scan for the owner event. A state row whose revision is above
    # `notified_revision` has a visible flip that no published event covers.
    # That is the case when the flip came from SQL that never reaches Ruby (a
    # wrapper or reference deleted with a plain DELETE, which the `statuses`
    # BEFORE DELETE trigger turns into an end of the share), or when the job
    # was refused by Sidekiq. The row is only visible here after its
    # transaction committed, so a rolled-back change is never announced.
    #
    # One pass enqueues at most BATCH jobs, oldest first, and skips rows that
    # changed within SETTLE seconds so the ordinary after-commit job goes
    # first. The job publishes the current row, so a duplicate is harmless.
    # The flag and the policy are not read: the state is the owner's.
    class RecoverUnnotified
      BATCH = 100
      SETTLE = 10.seconds

      def self.call(settle: SETTLE)
        new(settle).call
      end

      def initialize(settle)
        @settle = settle
      end

      def call
        pairs = ExternalProjectionLinkBoostState
                .where('revision > notified_revision')
                .where('updated_at <= ?', Time.current - @settle)
                .order(:updated_at)
                .limit(BATCH)
                .pluck(:user_id, :projection_status_id)
        pairs.each { |user_id, status_id| BoostEvents.enqueue(user_id.to_s, status_id.to_s) }
        pairs.size
      end
    end
  end
end
