# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Tells the owner's other sessions that the share state of one projection
    # may have changed. The job carries two decimal ids and nothing else. The
    # worker publishes whatever (revision, reblogged) row exists when it runs,
    # so a duplicate or reordered job cannot publish an older pair.
    #
    # The enqueue runs after the outermost commit only. If it fails, nothing is
    # lost that REST cannot restore: every REST and stream payload of the
    # projection carries the same revision, and the WebUI re-reads held
    # statuses on reconnect and on return to the tab.
    module BoostEvents
      module_function

      def changed!(user_id, projection_status_id)
        user = Streaming::Channels.decimal_id(user_id)
        status = Streaming::Channels.decimal_id(projection_status_id)
        return if user.nil? || status.nil?

        Streaming::AfterOuterCommit.run { enqueue(user, status) }
      end

      def enqueue(user_id, status_id)
        ExternalBridge::LinkBoostStreamWorker.perform_async(user_id, status_id)
      rescue Redis::BaseError => e
        Rails.logger.warn("[LinkSharing] boost state event not enqueued user_id=#{user_id} status_id=#{status_id} error=#{e.class}")
        nil
      end

      # A wrapper discarded outside Retire is ended by a database trigger in the
      # same statement. This only looks the pair up to notify.
      def wrapper_discarded!(wrapper_status_id)
        pair = ExternalProjectionLinkBoost.where(wrapper_status_id: wrapper_status_id).pick(:user_id, :projection_status_id)
        changed!(*pair) if pair
      rescue ActiveRecord::ActiveRecordError => e
        Rails.logger.warn("[LinkSharing] wrapper discard lookup failed error=#{e.class}")
        nil
      end
    end
  end
end
