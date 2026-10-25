# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Sends subscription_removed for an accepted unsubscribe, and can send it
    # again. control_enqueued_at is set only after Sidekiq returns a job id, or
    # when there is no destination to tell. A refused push, a Redis error, or a
    # database error while recording that id leaves the column null. The
    # deletion job and, for one day after the request, the recovery scheduler
    # try again, including after the deletion itself has completed. Nothing
    # here raises: the HTTP accept must not depend on this push.
    #
    # Sending it twice is safe. The client drops that subscription's items, and
    # StreamControlWorker still publishes while the row is deleting and once
    # the row has been destroyed. A connected screen that misses every send
    # drops the items on reload or reconnect, because the routes are already
    # gone, and the purge sends a delete per status.
    module SubscriptionRemovedNotice
      # How long a missed event stays eligible after the unsubscribe was accepted.
      WINDOW = 1.day

      module_function

      # @return [Boolean] true only when this call got a job id and recorded it
      def push!(deletion)
        return false if deletion.nil? || deletion.control_enqueued_at.present?

        outcome = deliver(deletion)
        return false if outcome == :failed
        return record_empty!(deletion) if outcome == :skipped

        record_pushed!(deletion)
      rescue StandardError => e
        log_failure(deletion, e)
        false
      end

      # One pass of the rows that still owe an event. Bounded by WINDOW and BATCH.
      def recover!(limit: 50)
        rows = ExternalSubscriptionDeletion.where(control_enqueued_at: nil)
                                           .where('requested_at > ?', WINDOW.ago)
                                           .order(:id)
                                           .limit(limit)
                                           .to_a
        rows.each { |deletion| push!(deletion) }
        rows.count { |deletion| deletion.control_enqueued_at.present? }
      end

      def deliver(deletion)
        return :skipped if Array(deletion.route_targets).empty?

        Streaming::Scheduler.deliver_control!(
          user_id: deletion.user_id,
          subscription_id: deletion.external_subscription_id,
          reason: 'subscription_removed',
          revision: revision_for(deletion),
          targets: deletion.route_targets
        )
      end

      def revision_for(deletion)
        ExternalSubscription.where(id: deletion.external_subscription_id).pick(:feed_routes_revision) || 0
      end

      # No destination, or this user cannot receive the event. Nothing is owed.
      def record_empty!(deletion)
        deletion.update_columns(control_enqueued_at: Time.current, updated_at: Time.current)
        false
      end

      def record_pushed!(deletion)
        deletion.update_columns(control_enqueued_at: Time.current, updated_at: Time.current)
        true
      end

      def log_failure(deletion, error)
        return if deletion.nil?

        SubscriptionDeletionLog.emit('enqueue_failed', deletion_id: deletion.id, error_class: error.class)
      end
    end
  end
end
