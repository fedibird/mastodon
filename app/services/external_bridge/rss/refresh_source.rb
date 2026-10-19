# frozen_string_literal: true

module ExternalBridge
  module RSS
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
        targets = permitted_subscriptions(source, subscription_id)
        return if targets.empty?

        response = HttpClient.get(source.canonical_key, etag: source.etag, last_modified: source.last_modified)
        if response.code == 304
          source.update!(checked_at: Time.current)
          resources = source.external_resources.order(published_at: :desc, id: :desc).limit(Limits::MAX_ITEMS).to_a
          materialize_targets(targets, resources)
        elsif response.code.between?(200, 299)
          feed = Parser.parse!(response.body)
          resources = Ingest.new.apply_public!(source, feed, response)
          materialize_targets(targets, resources)
        else
          code = [401, 403].include?(response.code) ? 'authenticated_source_rejected' : "http_#{response.code}"
          mark_subscriptions(targets, code)
        end
      end

      def permitted_subscriptions(source, subscription_id)
        scope = source.external_subscriptions.active.includes(:user)
        scope = scope.where(id: subscription_id) if subscription_id.present?
        scope.select { |subscription| Feature.permitted?(subscription.user) }
      end

      def materialize_targets(targets, resources)
        targets.each do |subscription|
          result = Materialize.new.call(subscription: subscription, resources: resources)
          SubscriptionOutcome.reconcile!(subscription, result) if result.ran
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] subscriber refresh failed subscription=#{subscription.id} code=#{e.class}")
          SubscriptionOutcome.retry!(subscription, 'import_failed')
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
        mark_subscriptions(permitted_subscriptions(source, subscription_id), code)
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
