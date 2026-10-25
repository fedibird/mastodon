# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Takes a wrapper whose share has ended to LinkWrapperRemovalWorker (the Undo for an
    # announced one) when the push that should have done it was lost, or the job
    # never finished.
    #
    # Retire.end! commits the row as `undone` and the wrapper as discarded in
    # the same transaction as the physical delete of the projection, and hands
    # the wrapper id to the caller for LinkWrapperRemovalWorker after the commit. A crash or
    # a Redis failure in between loses only that push, never the rows.
    #
    # The durable acknowledgement is removal_acknowledged_at, written by
    # LinkWrapperRemovalWorker once RemoveStatusService returned for the wrapper (the Undo
    # has been handed to ActivityPub delivery, whose workers retry on their own).
    # It is not the existence of the wrapper: Mastodon keeps a wrapper inside an
    # unresolved report (discarded, not destroyed), and that must neither be
    # destroyed here nor make this scan push it every ten minutes. The scan is
    # therefore `undone`, wrapper still referenced, not acknowledged. A wrapper
    # that never left the server is removed by Retire itself, which nulls the
    # column, so it never appears.
    #
    # A job that holds a live lease (removal_lease_until) is working on it; the
    # scan leaves such a row alone and picks it up again when the lease has
    # expired, which is how a worker that died is covered.
    #
    # Accepted by Sidekiq is not done: the claim only keeps one pass from
    # pushing the same wrapper again for HOLD. LinkWrapperRemovalWorker does nothing for a wrapper that
    # is already acknowledged, so a push that does arrive twice (a backlog longer
    # than HOLD) removes and Undoes once. The claim lives in
    # removal_next_attempt_at, separate from next_announce_at, which can still
    # hold the 30 minute Announce claim when a share ends soon after it was made.
    #
    # Worst case from a lost push to the next push: the scheduler period (5
    # minutes) plus SETTLE. Not gated by the feature flags: the share ended
    # already and the Undo is owed whatever the flags are now.
    class RecoverRemovals
      BATCH = 100
      SETTLE = 1.minute
      HOLD = 10.minutes

      def self.call(settle: SETTLE)
        new(settle).call
      end

      def initialize(settle)
        @settle = settle
      end

      def call
        rows = ExternalProjectionLinkBoost
               .where(state: 'undone', removal_acknowledged_at: nil)
               .where.not(wrapper_status_id: nil)
               .where('updated_at <= ?', Time.current - @settle)
               .where('removal_next_attempt_at IS NULL OR removal_next_attempt_at <= NOW()')
               .where('removal_lease_until IS NULL OR removal_lease_until <= NOW()')
               .order(Arel.sql('removal_next_attempt_at ASC NULLS FIRST, updated_at ASC'))
               .limit(BATCH)
               .pluck(:id, :wrapper_status_id)
        rows.count do |id, wrapper_id|
          next false unless claim(id, wrapper_id)

          pushed = push(wrapper_id)
          release(id) unless pushed
          pushed
        end
      end

      private

      def claim(id, wrapper_id)
        ExternalProjectionLinkBoost
          .where(id: id, state: 'undone', wrapper_status_id: wrapper_id, removal_acknowledged_at: nil)
          .where('removal_next_attempt_at IS NULL OR removal_next_attempt_at <= NOW()')
          .update_all(['removal_next_attempt_at = NOW() + make_interval(secs => ?)', HOLD.to_i]).positive?
      end

      # A refused push does not hold the row out for HOLD: the next pass tries
      # again.
      def release(id)
        ExternalProjectionLinkBoost.where(id: id, state: 'undone').update_all('removal_next_attempt_at = NOW()')
      end

      def push(wrapper_id)
        LinkWrapperRemovalWorker.perform_async(wrapper_id).present?
      rescue Redis::BaseError => e
        Rails.logger.warn("[LinkSharing] wrapper removal enqueue failed wrapper_id=#{wrapper_id} error=#{e.class}")
        false
      end
    end
  end
end
