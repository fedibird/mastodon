# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # One announce job per boost row, claimed before it is pushed. Same shape
    # as RecoverySchedule, on the boost table. announce_enqueued_at is the
    # durable mark that the ActivityPub job was accepted; next_announce_at only
    # keeps a scheduler pass from pushing a second job while the first one is
    # still held in Redis.
    module BoostSchedule
      CLAIM_FOR = 30.minutes
      CLAIM_STAMP = 'YYYY-MM-DD HH24:MI:SS.US'

      def self.enqueue!(id)
        claimed_until = claim!(id)
        return nil if claimed_until.nil?

        begin
          jid = ExternalBridge::LinkBoostAnnounceWorker.perform_async(id)
        rescue Redis::BaseError => e
          release_claim!(id, claimed_until)
          Rails.logger.warn("[LinkSharing] boost announce enqueue failed boost_id=#{id} error=#{e.class}")
          return nil
        end

        if jid.present?
          jid
        else
          release_claim!(id, claimed_until)
          Rails.logger.warn("[LinkSharing] boost announce was not enqueued boost_id=#{id}")
          nil
        end
      end

      # The reference Create has just been handed to distribution. Pending
      # boosts of that mapping are pushed without the claim: a job that ran
      # earlier and found the Create unfinished is already gone, and the
      # worker is idempotent under the row lock.
      def self.enqueue_for_mapping!(mapping_id)
        ids = ExternalProjectionLinkBoost.where(link_reference_id: mapping_id, state: 'active', announce_enqueued_at: nil).pluck(:id)
        ids.each do |id|
          ExternalBridge::LinkBoostAnnounceWorker.perform_async(id)
        rescue Redis::BaseError => e
          Rails.logger.warn("[LinkSharing] boost announce enqueue failed boost_id=#{id} error=#{e.class}")
        end
        ids.size
      end

      def self.claim!(id)
        connection = ExternalProjectionLinkBoost.connection
        connection.select_value(<<~SQL.squish)
          UPDATE external_projection_link_boosts
          SET next_announce_at = NOW() + make_interval(secs => #{CLAIM_FOR.to_i}),
              updated_at = CURRENT_TIMESTAMP
          WHERE id = #{connection.quote(id)}
            AND announce_enqueued_at IS NULL
            AND state = 'active'
            AND wrapper_status_id IS NOT NULL
            AND (next_announce_at IS NULL OR next_announce_at <= NOW())
          RETURNING to_char(next_announce_at, '#{CLAIM_STAMP}')
        SQL
      end

      def self.release_claim!(id, claimed_until)
        return if claimed_until.blank?

        connection = ExternalProjectionLinkBoost.connection
        connection.exec_update(<<~SQL.squish)
          UPDATE external_projection_link_boosts
          SET next_announce_at = NOW(), updated_at = CURRENT_TIMESTAMP
          WHERE id = #{connection.quote(id)}
            AND announce_enqueued_at IS NULL
            AND to_char(next_announce_at, '#{CLAIM_STAMP}') = #{connection.quote(claimed_until)}
        SQL
      end
    end
  end
end
