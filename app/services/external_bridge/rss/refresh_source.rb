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
        response = HttpClient.get(source.canonical_key, etag: source.etag, last_modified: source.last_modified)
        if response.code == 304
          source.update!(checked_at: Time.current)
          resources = source.external_resources.order(published_at: :desc, id: :desc).limit(Limits::MAX_ITEMS).to_a
          materialize_active(source, resources, complete: false)
        elsif response.code.between?(200, 299)
          feed = Parser.parse!(response.body)
          resources = Ingest.new.apply_public!(source, feed, response)
          materialize_active(source, resources, complete: feed.items.size < Limits::MAX_ITEMS)
        elsif [401, 403].include?(response.code)
          mark_private_failure(source, subscription_id)
        else
          mark_error(source, subscription_id, "http_#{response.code}")
        end
      end

      def materialize_active(source, resources, complete:)
        source.external_subscriptions.active.includes(:user).find_each do |subscription|
          Materialize.new.call(subscription: subscription, resources: resources, complete: complete)
          subscription.update!(state: 'active', last_error_code: nil, last_error_at: nil, checked_at: Time.current)
        end
      end

      def mark_private_failure(source, subscription_id)
        source.update!(checked_at: Time.current)
        mark_error(source, subscription_id, 'authenticated_source_rejected')
      end

      def mark_error(source, subscription_id, code)
        scope = source.external_subscriptions
        scope = scope.where(id: subscription_id) if subscription_id.present?
        scope.find_each do |subscription|
          subscription.update!(state: 'error', last_error_code: code, last_error_at: Time.current, checked_at: Time.current)
        end
      end

      def record_failure(source_id, subscription_id, code)
        source = ExternalSource.find_by(id: source_id)
        return if source.nil?

        Rails.logger.info("[ExternalBridge::RSS] refresh failed host_key=#{source.id} code=#{code}")
        mark_error(source, subscription_id, code)
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
