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
    # Same shape as E4-A RecoverySchedule. One pass takes at most BATCH rows
    # that changed at least SETTLE ago, ordered by `next_notify_at ASC NULLS
    # FIRST, updated_at`, and claims each before it pushes a job:
    #
    # - null: not visited since the last flip (a flip resets it in the state
    #   trigger), so a row that was never tried is always ahead of a row that
    #   was.
    # - a future time: Sidekiq accepted a job (a jid came back). The row is held
    #   out of the scan for HOLD, so the same pair is not pushed again every
    #   minute while that job waits in Redis.
    # - a past time: the enqueue was refused (nil jid, Redis error) and the claim
    #   was released to "now", or the hold ran out because the job was lost or
    #   failed. The row is tried again after every never-tried row.
    #
    # A failing head therefore cannot starve the rows behind it: it is claimed
    # or moved behind them on the pass that selects it. The job publishes the
    # current row and acknowledges `notified_revision` (never backwards), so a
    # duplicate is harmless and a flip after the claim is found again. The flag
    # and the policy are not read: the state is the owner's.
    class RecoverUnnotified
      BATCH = 100
      SETTLE = 10.seconds
      HOLD = 10.minutes
      CLAIM_STAMP = 'YYYY-MM-DD HH24:MI:SS.US'

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
                .where('next_notify_at IS NULL OR next_notify_at <= NOW()')
                .order(Arel.sql('next_notify_at ASC NULLS FIRST, updated_at ASC'))
                .limit(BATCH)
                .pluck(:user_id, :projection_status_id)
        pairs.each { |user_id, status_id| enqueue_claimed(user_id, status_id) }
        pairs.size
      end

      private

      def enqueue_claimed(user_id, status_id)
        claimed_until = claim!(user_id, status_id)
        return if claimed_until.nil?

        jid = BoostEvents.enqueue(user_id.to_s, status_id.to_s)
        return if jid.present?

        release_claim!(user_id, status_id, claimed_until)
        Rails.logger.warn("[LinkSharing] boost state event was not enqueued user_id=#{user_id} status_id=#{status_id}")
      end

      def claim!(user_id, status_id)
        connection = ExternalProjectionLinkBoostState.connection
        connection.select_value(<<~SQL.squish)
          UPDATE external_projection_link_boost_states
          SET next_notify_at = NOW() + make_interval(secs => #{HOLD.to_i})
          WHERE user_id = #{connection.quote(user_id)}
            AND projection_status_id = #{connection.quote(status_id)}
            AND revision > notified_revision
            AND (next_notify_at IS NULL OR next_notify_at <= NOW())
          RETURNING to_char(next_notify_at, '#{CLAIM_STAMP}')
        SQL
      end

      # Only the claim this pass took is released. A flip since then reset the
      # column to null, and a later pass may hold a newer claim; neither is
      # touched.
      def release_claim!(user_id, status_id, claimed_until)
        connection = ExternalProjectionLinkBoostState.connection
        connection.exec_update(<<~SQL.squish)
          UPDATE external_projection_link_boost_states
          SET next_notify_at = NOW()
          WHERE user_id = #{connection.quote(user_id)}
            AND projection_status_id = #{connection.quote(status_id)}
            AND to_char(next_notify_at, '#{CLAIM_STAMP}') = #{connection.quote(claimed_until)}
        SQL
      end
    end
  end
end
