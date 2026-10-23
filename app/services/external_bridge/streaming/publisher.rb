# frozen_string_literal: true

module ExternalBridge
  module Streaming
    # Publishes one private event. The payload is the client body or an id.
    # This object does not log either of those.
    class Publisher
      include Redisable

      def publish(channel, event, payload)
        return false if channel.blank?

        redis.publish(channel, Oj.dump(event: event.to_s, payload: payload, queued_at: (Time.now.to_f * 1000.0).to_i))
        true
      end
    end
  end
end
