# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Saves the owner's display choices and queues a rewrite of the statuses
    # already imported for this subscription. The request returns after the
    # row is stored. It does not walk the projection history.
    class PresentationUpdate
      OMIT = :omit

      def call(user:, subscription_id:, media_sensitive: OMIT, cw_enabled: OMIT)
        attrs = flags(media_sensitive, cw_enabled)
        subscription = nil
        ExternalSubscription.transaction do
          subscription = ExternalSubscription.lock.find_by(id: subscription_id, user_id: user.id)
          raise Error, :not_found if subscription.nil?
          raise Error, :subscription_deleting if subscription.deleting?

          unless unchanged?(subscription, attrs)
            now = Time.current
            token = SecureRandom.hex(16)
            sql = "#{attrs.keys.map { |key| "#{key} = ?" }.join(', ')}, presentation_revision = presentation_revision + 1, presentation_error = NULL, presentation_lease_token = ?, presentation_lease_until = ?, updated_at = ?"
            updated = ExternalSubscription.where(id: subscription.id).where.not(state: ExternalSubscription::DELETING).update_all(
              [sql, *attrs.values, token, now + PresentationReconcileWorker::LEASE, now]
            )
            raise Error, ExternalSubscription.exists?(subscription.id) ? :subscription_deleting : :not_found if updated.zero?

            enqueue(subscription.id, token)
          end
        end
        subscription.reload
      end

      private

      def flags(media_sensitive, cw_enabled)
        attrs = {}
        attrs[:media_sensitive] = cast(media_sensitive) unless media_sensitive == OMIT
        attrs[:cw_enabled] = cast(cw_enabled) unless cw_enabled == OMIT
        raise Error, :invalid_presentation if attrs.empty?

        attrs
      end

      def unchanged?(subscription, attrs)
        attrs.all? { |key, value| subscription.public_send(key) == value }
      end

      def cast(value)
        return true if [true, 1, '1', 'true', 'TRUE'].include?(value)
        return false if [false, 0, '0', 'false', 'FALSE'].include?(value)

        raise Error, :invalid_presentation
      end

      # The generation is read again at enqueue time. A newer save replaces the
      # token, and this callback then queues nothing: the newer save queues
      # the token that still owns the row.
      def enqueue(subscription_id, token)
        Streaming::AfterOuterCommit.run do
          current = ExternalSubscription.find_by(id: subscription_id)
          if current && !current.deleting? && current.presentation_lease_token == token && current.presentation_revision.to_i > current.presentation_applied_revision.to_i
            PresentationReconcileWorker.perform_async(current.id, current.presentation_revision.to_i, 0, token)
          end
        rescue Redis::BaseError => e
          Rails.logger.info("[ExternalBridge::RSS] presentation enqueue error=#{e.class}")
        end
      end
    end
  end
end
