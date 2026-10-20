# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Shared-source fetch versus per-subscription retry accounting.
    #
    # Scheduler (no subscription_id): fetch when at least one active allowed
    # subscription is due. HTTP failure increments retry state only for those
    # due rows. A subscriber whose next_retry_at is still in the future keeps
    # that deadline and retry_count. On success the new public items are also
    # offered to the other active allowed subscribers, without reconcile, without
    # their historical failure backlog, and without changing their counters.
    #
    # Targeted resume (subscription_id): that subscription is the only row whose
    # failure and retry state can change, even when its deadline has not arrived.
    # Other subscribers are offered a successful cache fill on the same terms.
    class RefreshSource
      def call(source_id, subscription_id: nil)
        return unless Feature.enabled?

        source = ExternalSource.find_by(id: source_id)
        return if source.nil?

        with_source_lock(source.id) do
          refresh_locked(source, subscription_id)
        end
      rescue Error => e
        record_failure(source_id, subscription_id, e.code)
      end

      private

      def refresh_locked(source, subscription_id)
        permitted = active_permitted(source)
        accounted = accounted_subscriptions(permitted, subscription_id)
        return if accounted.empty?

        response = HttpClient.get(source.canonical_key, etag: source.etag, last_modified: source.last_modified)
        if response.code == 304
          source.update!(checked_at: Time.current)
          resources = source.external_resources.order(published_at: :desc, id: :desc).limit(Limits::MAX_ITEMS).to_a
          apply_resources(permitted, accounted, resources)
        elsif response.code.between?(200, 299)
          feed = Parser.parse!(response.body)
          resources = Ingest.new.apply_public!(source, feed, response)
          apply_resources(permitted, accounted, resources)
        else
          code = [401, 403].include?(response.code) ? 'authenticated_source_rejected' : "http_#{response.code}"
          mark_subscriptions(accounted, code)
        end
      end

      def apply_resources(permitted, accounted, resources)
        materialize_accounted(accounted, resources)
        offer_shared_cache(permitted, accounted, resources)
      end

      def active_permitted(source)
        source.external_subscriptions.active.includes(:user).select { |subscription| Feature.permitted?(subscription.user) }
      end

      def accounted_subscriptions(permitted, subscription_id)
        if subscription_id.present?
          permitted.select { |subscription| subscription.id == subscription_id.to_i }
        else
          due_ids = ExternalSubscription.due_for_refresh.where(id: permitted.map(&:id)).ids
          permitted.select { |subscription| due_ids.include?(subscription.id) }
        end
      end

      def materialize_accounted(targets, resources)
        targets.each do |subscription|
          result = Materialize.new.call(subscription: subscription, resources: resources, retries: true)
          SubscriptionOutcome.reconcile!(subscription, result) if result.ran
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] subscriber refresh failed subscription=#{subscription.id} code=#{e.class}")
          SubscriptionOutcome.retry!(subscription, 'import_failed')
        end
      end

      def offer_shared_cache(permitted, accounted, resources)
        accounted_ids = accounted.map(&:id)
        permitted.each do |subscription|
          next if accounted_ids.include?(subscription.id)

          Materialize.new.call(subscription: subscription, resources: resources, retries: false)
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] shared cache offer skipped subscription=#{subscription.id} code=#{e.class}")
        end
      end

      def mark_subscriptions(targets, code)
        targets.each do |subscription|
          SubscriptionOutcome.fetch_failure!(subscription, code)
        end
      end

      def record_failure(source_id, subscription_id, code)
        source = ExternalSource.find_by(id: source_id)
        return if source.nil?

        Rails.logger.info("[ExternalBridge::RSS] refresh failed host_key=#{source.id} code=#{code}")
        permitted = active_permitted(source)
        mark_subscriptions(accounted_subscriptions(permitted, subscription_id), code)
      end

      def with_source_lock(source_id)
        connection = ActiveRecord::Base.connection
        locked = connection.select_value(ActiveRecord::Base.sanitize_sql_array(['SELECT pg_try_advisory_lock(810531, ?)', source_id.to_i]))
        return unless locked == true || locked.to_s == 't'

        yield
      ensure
        if locked == true || locked.to_s == 't'
          connection.execute(ActiveRecord::Base.sanitize_sql_array(['SELECT pg_advisory_unlock(810531, ?)', source_id.to_i]))
        end
      end
    end
  end
end
