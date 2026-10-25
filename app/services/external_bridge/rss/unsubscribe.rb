# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Accepts an unsubscribe without waiting for the data to go.
    #
    # One short transaction, holding the subscription row FOR UPDATE:
    #
    #   1. the feed routes are deleted, which takes the subscription's items out
    #      of every home/list read and every streaming membership query at once;
    #   2. the row moves to `deleting`, the fence every writer respects;
    #   3. the owner's ExternalSubscriptionDeletion is written, keeping the
    #      destinations in route_targets.
    #
    # After that commit, and only then, two pushes are attempted. Neither can
    # fail the request: the database accept is already durable. The deletion
    # job is recovered by the scheduler through next_run_at. The
    # subscription_removed streaming event is recovered by the same job from
    # route_targets (SubscriptionRemovedNotice). A live WebUI that misses the
    # event still drops the items on reload or reconnect, because membership is
    # read from the routes, which are already gone, and the purge sends a
    # delete for each status. A repeated request returns the same record.
    class Unsubscribe
      # How long the recovery scheduler leaves a fresh request alone, so it does
      # not race the push that follows the commit.
      DISPATCH_GRACE = 2.minutes

      def call(user:, subscription_id:)
        raise Error, :not_found if user.nil?

        deletion, created = ApplicationRecord.transaction { accept!(user, subscription_id) }
        if created
          # After the commit. A failure here is logged and leaves the event
          # unacked. It must not skip the deletion job or fail the request.
          begin
            SubscriptionRemovedNotice.push!(deletion)
          rescue StandardError => e
            SubscriptionDeletionLog.emit('enqueue_failed', deletion_id: deletion.id, error_class: e.class)
          end
          SubscriptionDeletionDispatch.enqueue(deletion.id)
        end
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
    end
  end
end
