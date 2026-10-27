# frozen_string_literal: true

module ExternalBridge
  module RSS
    class Subscribe
      def call(user:, url:)
        raise Error, :feature_disabled unless Feature.enabled?
        raise Error, :tester_only unless Feature.tester?(user)
        raise Error, :user_not_functional unless user&.functional?

        canonical = CanonicalURL.normalize!(url)
        source = ExternalSource.find_by(canonical_key: canonical)
        assert_not_deleting!(user, source)
        if source && fresh?(source)
          subscription = ensure_subscription!(user, source)
          materialize!(subscription, source)
          Icon::Schedule.enqueue_if_due(source)
          ActivityPub::Schedule.enqueue_if_due(source)
          return subscription
        end

        response = HttpClient.get(canonical, etag: source&.etag, last_modified: source&.last_modified)
        apply_response!(user, canonical, source, response)
      end

      def pause!(user:, subscription_id:)
        subscription = owned!(user, subscription_id)
        transition!(subscription, state: 'paused')
        subscription
      end

      def resume!(user:, subscription_id:)
        raise Error, :feature_disabled unless Feature.enabled?
        raise Error, :tester_only unless Feature.tester?(user)

        subscription = owned!(user, subscription_id)
        transition!(subscription, state: 'active', last_error_code: nil, last_error_at: nil, next_retry_at: nil, retry_count: 0)
        subscription.external_projection_failures.update_all(attempt_count: 0, next_attempt_at: nil)
        RefreshSource.new.call(subscription.external_source_id, subscription_id: subscription.id)
        subscription.reload
      end

      def restore!(user:, subscription_id:, resource_id: nil)
        raise Error, :feature_disabled unless Feature.enabled?
        raise Error, :tester_only unless Feature.tester?(user)

        subscription = owned!(user, subscription_id)
        raise Error, :user_not_functional unless user&.functional?

        scope = ExternalProjectionSuppression.where(user_id: user.id, external_resource_id: source_resource_ids(subscription))
        scope = scope.where(external_resource_id: resource_id) if resource_id.present?
        ids = scope.pluck(:external_resource_id)
        raise Error, :not_found if ids.empty?

        scope.delete_all
        resources = ExternalResource.where(id: ids).to_a
        result = Materialize.new.call(subscription: subscription, resources: resources)
        SubscriptionOutcome.reconcile!(subscription, result) if result.ran
        subscription.reload
      end

      # Accepts the unsubscribe and returns at once. The subscription is fenced
      # (`deleting`) and a durable job record is written in one short
      # transaction; the physical removal runs in
      # SubscriptionDeletionWorker. The return value is the owner's
      # ExternalSubscriptionDeletion, the same record for a repeated request.
      def unsubscribe!(user:, subscription_id:)
        Unsubscribe.new.call(user: user, subscription_id: subscription_id)
      end

      private

      def apply_response!(user, canonical, source, response)
        if response.code == 304 && source
          source.update!(checked_at: Time.current)
          subscription = ensure_subscription!(user, source)
          materialize!(subscription, source)
          Icon::Schedule.enqueue_if_due(source)
          ActivityPub::Schedule.enqueue_if_due(source)
          return subscription
        end

        unless response.code.between?(200, 299)
          code = [401, 403].include?(response.code) ? 'authenticated_source_rejected' : "http_#{response.code}"
          record_existing_error(source, user, code)
          raise Error, code
        end

        feed = Parser.parse!(response.body)
        canonical_key = response.final_url.presence || canonical
        source, = Ingest.new.write_public!(feed, canonical_key, response)
        subscription = ensure_subscription!(user, source)
        materialize!(subscription, source)
        Icon::Schedule.enqueue_if_due(source)
        ActivityPub::Schedule.enqueue_if_due(source)
        subscription
      rescue Error => e
        record_existing_error(source, user, e.code) if source&.persisted?
        raise
      end

      def fresh?(source)
        source.fetched_at.present? && source.fetched_at > Limits::FRESH_FOR.ago && source.external_resources.exists?
      end

      # The row is locked while it is read, so a subscription that is fenced
      # between the read and the save cannot be written back to `active`.
      def ensure_subscription!(user, source)
        ExternalSubscription.transaction do
          subscription = ExternalSubscription.lock.find_by(user_id: user.id, external_source_id: source.id)
          raise Error, :subscription_deleting if subscription&.deleting?

          subscription ||= ExternalSubscription.new(user_id: user.id, external_source_id: source.id)
          subscription.state = 'active'
          subscription.last_error_code = nil
          subscription.last_error_at = nil
          subscription.checked_at = Time.current
          subscription.next_retry_at = nil
          subscription.save!
          subscription
        end
      end

      def assert_not_deleting!(user, source)
        return if source.nil?
        return unless ExternalSubscription.where(user_id: user.id, external_source_id: source.id, state: ExternalSubscription::DELETING).exists?

        raise Error, :subscription_deleting
      end

      def transition!(subscription, attributes)
        return if subscription.update_unless_deleting!(attributes)

        raise Error, ExternalSubscription.exists?(subscription.id) ? :subscription_deleting : :not_found
      end

      def materialize!(subscription, source)
        resources = source.external_resources.order(published_at: :desc, id: :desc).limit(Limits::MAX_ITEMS).to_a
        result = Materialize.new.call(subscription: subscription, resources: resources)
        SubscriptionOutcome.reconcile!(subscription, result) if result.ran
        subscription
      end

      def owned!(user, subscription_id)
        subscription = ExternalSubscription.find_by(id: subscription_id, user_id: user.id) || raise(Error, :not_found)
        raise Error, :subscription_deleting if subscription.deleting?

        subscription
      end

      def source_resource_ids(subscription)
        ExternalResource.where(external_source_id: subscription.external_source_id).select(:id)
      end

      def record_existing_error(source, user, code)
        return if source.nil? || !source.persisted?

        subscription = ExternalSubscription.find_by(user_id: user.id, external_source_id: source.id)
        return if subscription.nil?

        SubscriptionOutcome.fetch_failure!(subscription, code)
      end
    end
  end
end
