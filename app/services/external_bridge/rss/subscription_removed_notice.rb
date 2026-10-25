# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Sends subscription_removed for an accepted unsubscribe, and can send it
    # again. The deletion row is the record: control_enqueued_at is set only
    # after Sidekiq accepts the job. A Redis error leaves it null, and the next
    # deletion run tries again. route_targets is the payload, so the event can
    # be rebuilt after the routes themselves are gone.
    #
    # Sending it twice is safe. The client drops that subscription's items, and
    # StreamControlWorker still publishes while the row is deleting and once
    # the row has been destroyed.
    module SubscriptionRemovedNotice
      module_function

      def push!(deletion)
        return false if deletion.nil? || deletion.control_enqueued_at.present?

        outcome = deliver(deletion)
        return false if outcome == :failed

        deletion.update_columns(control_enqueued_at: Time.current, updated_at: Time.current)
        outcome == :pushed
      rescue Redis::BaseError => e
        SubscriptionDeletionLog.emit('enqueue_failed', deletion_id: deletion.id, error_class: e.class)
        false
      end

      def deliver(deletion)
        targets = Array(deletion.route_targets)
        return :empty if targets.empty?

        Streaming::Scheduler.deliver_control!(
          user_id: deletion.user_id,
          subscription_id: deletion.external_subscription_id,
          reason: 'subscription_removed',
          revision: revision_for(deletion),
          targets: targets
        )
      end

      def revision_for(deletion)
        ExternalSubscription.where(id: deletion.external_subscription_id).pick(:feed_routes_revision) || 0
      end
    end
  end
end
