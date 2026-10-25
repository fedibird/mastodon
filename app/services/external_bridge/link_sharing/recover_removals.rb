# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Takes a wrapper whose share has ended to RemovalWorker (the Undo for an
    # announced one) when the push that should have done it was lost.
    #
    # Retire.end! commits the row as `undone` and the wrapper as discarded in
    # the same transaction as the physical delete of the projection, and hands
    # the wrapper id to the caller for RemovalWorker after the commit. A crash or
    # a Redis failure in between loses only that push, never the rows. The row
    # is the durable record: an `undone` boost whose wrapper_status_id is still
    # set has a wrapper that RemovalWorker has not removed yet (removing the
    # wrapper nulls the column through ON DELETE SET NULL, and a wrapper that
    # never left the server is removed by Retire itself). That is the whole scan,
    # and it holds no row that is finished.
    #
    # Pushing is idempotent. RemovalWorker removes a status that is gone as a
    # no-op, RemoveStatusService sends the Undo once per wrapper, and a second
    # job for a wrapper that is already removed finds nothing. A claim in
    # next_announce_at (unused once a row is undone) keeps one pass from pushing
    # the same wrapper again while the first job waits in Redis.
    #
    # Not gated by the feature flags: the share ended already and the Undo is
    # owed whatever the flags are now.
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
               .where(state: 'undone')
               .where.not(wrapper_status_id: nil)
               .where('updated_at <= ?', Time.current - @settle)
               .where('next_announce_at IS NULL OR next_announce_at <= NOW()')
               .order(Arel.sql('next_announce_at ASC NULLS FIRST, updated_at ASC'))
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
          .where(id: id, state: 'undone', wrapper_status_id: wrapper_id)
          .where('next_announce_at IS NULL OR next_announce_at <= NOW()')
          .update_all(['next_announce_at = NOW() + make_interval(secs => ?)', HOLD.to_i]).positive?
      end

      # A refused push does not hold the row out for HOLD: the next pass tries
      # again.
      def release(id)
        ExternalProjectionLinkBoost.where(id: id, state: 'undone').update_all('next_announce_at = NOW()')
      end

      def push(wrapper_id)
        RemovalWorker.perform_async(wrapper_id).present?
      rescue Redis::BaseError => e
        Rails.logger.warn("[LinkSharing] wrapper removal enqueue failed wrapper_id=#{wrapper_id} error=#{e.class}")
        false
      end
    end
  end
end
