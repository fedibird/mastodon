# frozen_string_literal: true

module ExternalBridge
  class StreamControlWorker
    include Sidekiq::Worker

    def perform(user_id, payload, delivery = nil)
      return unless payload.is_a?(Hash)

      user = User.find_by(id: user_id)
      return unless user&.functional?
      return unless ExternalBridge::Feeds::Feature.permitted?(user)
      return unless current_enough?(user, payload)

      channel = ExternalBridge::Streaming::Channels.control(user.id)
      return if channel.nil?

      # Route row ids stay on the Redis envelope. The client payload does not
      # carry them.
      ExternalBridge::Streaming::Publisher.new.publish(
        channel,
        'external_feed_changed',
        payload,
        delivery: delivery.is_a?(Hash) ? delivery : nil
      )
    rescue Redis::BaseError, ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[ExternalBridge::Streaming] control user_id=#{user_id} error=#{e.class}")
      raise
    end

    private

    def current_enough?(user, payload)
      reason = payload['reason'].to_s
      subscription = ExternalSubscription.find_by(id: payload['subscription_id'], user_id: user.id)
      # Sent when the unsubscribe is accepted (the row is `deleting`) and, for
      # a row that was removed without the fence, once it is gone.
      return subscription.nil? || subscription.deleting? if reason == 'subscription_removed'
      return false if subscription.nil?

      revision = payload['feed_routes_revision'].to_s
      return false unless revision.match?(/\A(?:0|[1-9]\d*)\z/)

      subscription.feed_routes_revision.to_i >= revision.to_i
    end
  end
end
