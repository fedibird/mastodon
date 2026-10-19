# frozen_string_literal: true

module ExternalBridge
  module RSS
    class Subscribe
      def call(user:, url:)
        raise Error, :feature_disabled unless Feature.enabled?
        raise Error, :user_not_functional unless user&.functional?

        canonical = CanonicalURL.normalize!(url)
        source = ExternalSource.find_by(canonical_key: canonical)
        if source && fresh?(source)
          subscription = ensure_subscription!(user, source)
          materialize!(subscription, source)
          return subscription
        end

        response = HttpClient.get(canonical, etag: source&.etag, last_modified: source&.last_modified)
        apply_response!(user, canonical, source, response)
      end

      def pause!(user:, subscription_id:)
        subscription = owned!(user, subscription_id)
        subscription.update!(state: 'paused')
        subscription
      end

      def resume!(user:, subscription_id:)
        raise Error, :feature_disabled unless Feature.enabled?

        subscription = owned!(user, subscription_id)
        subscription.update!(state: 'active', last_error_code: nil)
        RefreshSource.new.call(subscription.external_source_id, subscription_id: subscription.id)
        subscription.reload
      end

      def unsubscribe!(user:, subscription_id:)
        subscription = owned!(user, subscription_id)
        ApplicationRecord.transaction do
          ProjectionPurge.purge_subscription!(subscription)
          subscription.destroy!
        end
        true
      end

      private

      def apply_response!(user, canonical, source, response)
        if response.code == 304 && source
          source.update!(checked_at: Time.current)
          subscription = ensure_subscription!(user, source)
          materialize!(subscription, source)
          return subscription
        end

        unless response.code.between?(200, 299)
          code = [401, 403].include?(response.code) ? 'authenticated_source_rejected' : "http_#{response.code}"
          record_existing_error(source, user, code)
          raise Error, code
        end

        feed = Parser.parse!(response.body)
        source = Ingest.new.find_or_create_source!(feed, response.final_url.presence || canonical)
        Ingest.new.apply_public!(source, feed, response)
        subscription = ensure_subscription!(user, source)
        materialize!(subscription, source)
        subscription
      rescue Error => e
        record_existing_error(source, user, e.code) if source&.persisted?
        raise
      end

      def fresh?(source)
        source.fetched_at.present? && source.fetched_at > Limits::FRESH_FOR.ago && source.external_resources.exists?
      end

      def ensure_subscription!(user, source)
        subscription = ExternalSubscription.find_or_initialize_by(user_id: user.id, external_source_id: source.id)
        subscription.state = 'active'
        subscription.last_error_code = nil
        subscription.last_error_at = nil
        subscription.checked_at = Time.current
        subscription.save!
        subscription
      end

      def materialize!(subscription, source)
        resources = source.external_resources.order(published_at: :desc, id: :desc).limit(Limits::MAX_ITEMS).to_a
        Materialize.new.call(subscription: subscription, resources: resources, complete: false)
        subscription
      end

      def owned!(user, subscription_id)
        ExternalSubscription.find_by(id: subscription_id, user_id: user.id) || raise(Error, :not_found)
      end

      def record_existing_error(source, user, code)
        return if source.nil? || !source.persisted?

        subscription = ExternalSubscription.find_by(user_id: user.id, external_source_id: source.id)
        return if subscription.nil?

        subscription.update!(state: 'error', last_error_code: code, last_error_at: Time.current, checked_at: Time.current)
      end
    end
  end
end
