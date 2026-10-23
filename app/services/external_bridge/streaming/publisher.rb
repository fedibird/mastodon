# frozen_string_literal: true

module ExternalBridge
  module Streaming
    # Publishes one private event. The payload is the client body or an id.
    # This object does not log either of those.
    class Publisher
      include Redisable

      # `delivery` stays on the Redis envelope. Node strips it before the
      # public WebSocket or SSE frame. It is ids and a generation, never text.
      def publish(channel, event, payload, delivery: nil)
        return false if channel.blank?

        envelope = { event: event.to_s, payload: payload, queued_at: (Time.now.to_f * 1000.0).to_i }
        envelope[:delivery] = delivery if delivery
        redis.publish(channel, Oj.dump(envelope))
        true
      end
    end
  end
end
