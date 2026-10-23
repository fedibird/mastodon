# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # One mapping's place in the unpublished recovery scan.
    #
    # next_recovery_at NULL means this row has not been visited. Those rows
    # are selected first, so a stuck head cannot keep the scan on the same
    # ids. A time in the future means Sidekiq accepted a job. The row stays
    # out of the scan until that time, which is longer than four scheduler
    # passes. A time at or before now means the enqueue was refused or the
    # claim expired, and the row may be tried again.
    #
    # Ensure and the scheduler both enqueue through enqueue!. The claim is
    # taken before perform_async. A nil jid or a Redis connection error
    # clears only the timestamp this attempt wrote. A later claim from
    # another caller is left in place.
    module RecoverySchedule
      CLAIM_FOR = 30.minutes
      CLAIM_STAMP = 'YYYY-MM-DD HH24:MI:SS.US'

      def self.enqueue!(id)
        claimed_until = claim!(id)
        return nil if claimed_until.nil?

        begin
          jid = ExternalBridge::LinkReferencePublishWorker.perform_async(id)
        rescue Redis::BaseError => e
          release_claim!(id, claimed_until)
          Rails.logger.warn("[LinkSharing] reference publish enqueue failed mapping_id=#{id} error=#{e.class}")
          return nil
        end

        if jid.present?
          jid
        else
          release_claim!(id, claimed_until)
          Rails.logger.warn("[LinkSharing] reference publish was not enqueued mapping_id=#{id}")
          nil
        end
      end

      def self.claim!(id)
        connection = ExternalProjectionLinkReference.connection
        connection.select_value(<<~SQL.squish)
          UPDATE external_projection_link_references
          SET next_recovery_at = NOW() + make_interval(secs => #{CLAIM_FOR.to_i}),
              updated_at = CURRENT_TIMESTAMP
          WHERE id = #{connection.quote(id)}
            AND published_at IS NULL
            AND state IN ('active', 'superseded')
            AND reference_status_id IS NOT NULL
            AND (next_recovery_at IS NULL OR next_recovery_at <= NOW())
          RETURNING to_char(next_recovery_at, '#{CLAIM_STAMP}')
        SQL
      end

      # Clears the claim only when it is still the timestamp this attempt
      # stored. A newer claim, or a row that has since been published, stays.
      def self.release_claim!(id, claimed_until)
        return if claimed_until.blank?

        connection = ExternalProjectionLinkReference.connection
        connection.exec_update(<<~SQL.squish)
          UPDATE external_projection_link_references
          SET next_recovery_at = NOW(), updated_at = CURRENT_TIMESTAMP
          WHERE id = #{connection.quote(id)}
            AND published_at IS NULL
            AND to_char(next_recovery_at, '#{CLAIM_STAMP}') = #{connection.quote(claimed_until)}
        SQL
      end
    end
  end
end
