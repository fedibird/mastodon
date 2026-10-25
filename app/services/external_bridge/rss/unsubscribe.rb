# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Accepts an unsubscribe without waiting for the data to go.
    #
    # One short transaction, holding the subscription row FOR UPDATE:
    #
    #   1. the `subscription_removed` control event is scheduled (it is sent
    #      after the commit) with the destinations the routes had;
    #   2. the feed routes are deleted, which takes the subscription's items out
    #      of every home/list read and every streaming membership query at once;
    #   3. the row moves to `deleting`, the fence every writer respects;
    #   4. the owner's ExternalSubscriptionDeletion is written.
    #
    # Only after that commit is the Sidekiq job pushed. A refused push or a
    # crashed web process is repaired by the recovery scheduler through
    # next_run_at, so `deleting` cannot be left behind. A repeated request, a
    # double click, or a request after completion returns the same record.
    class Unsubscribe
      # How long the recovery scheduler leaves a fresh request alone, so it does
      # not race the push that follows the commit.
      DISPATCH_GRACE = 2.minutes

      def call(user:, subscription_id:)
        raise Error, :not_found if user.nil?

        deletion, created = ApplicationRecord.transaction { accept!(user, subscription_id) }
        SubscriptionDeletionDispatch.enqueue(deletion.id) if created
        deletion
      end

      private

      # @return [Array(ExternalSubscriptionDeletion, Boolean)] the record and
      #   whether this call created it. A repeated request pushes nothing: the
      #   first push, or the recovery scheduler, owns the job.
      def accept!(user, subscription_id)
        subscription = ExternalSubscription.lock.find_by(id: subscription_id, user_id: user.id)
        if subscription.nil?
          return [recorded(user, subscription_id) || raise(Error, :not_found), false]
        end

        existing = ExternalSubscriptionDeletion.find_by(external_subscription_id: subscription.id)
        return [existing, false] if existing

        [fence!(subscription), true]
      end

      def recorded(user, subscription_id)
        id = Integer(subscription_id.to_s, 10)
        ExternalSubscriptionDeletion.find_by(user_id: user.id, external_subscription_id: id)
      rescue ArgumentError, RangeError
        nil
      end

      def fence!(subscription)
        targets = route_targets(subscription)
        schedule_removed_event(subscription, targets)
        ExternalFeedRoute.where(external_subscription_id: subscription.id).delete_all
        now = Time.current
        subscription.update_columns(state: ExternalSubscription::DELETING, next_retry_at: nil, updated_at: now)
        ExternalSubscriptionDeletion.create!(
          user_id: subscription.user_id,
          external_subscription_id: subscription.id,
          external_source_id: subscription.external_source_id,
          state: 'queued',
          route_targets: targets,
          requested_at: now,
          next_run_at: now + DISPATCH_GRACE
        )
      end

      def route_targets(subscription)
        subscription.external_feed_routes.filter_map do |route|
          if route.destination == 'home'
            { 'type' => 'home' }
          elsif route.list_id.present?
            { 'type' => 'list', 'id' => route.list_id.to_s }
          end
        end.uniq
      end

      def schedule_removed_event(subscription, targets)
        return if targets.empty?

        Streaming::Scheduler.schedule_control!(
          user_id: subscription.user_id,
          subscription_id: subscription.id,
          reason: 'subscription_removed',
          revision: subscription.feed_routes_revision,
          targets: targets
        )
      end
    end
  end
end
