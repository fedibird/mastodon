# frozen_string_literal: true

module Reboost
  COOLDOWN_SECONDS = 300 unless const_defined?(:COOLDOWN_SECONDS, false)
  FEDERATION_GAP = 10.seconds unless const_defined?(:FEDERATION_GAP, false)

  # Structured log plus a global Redis counter. Counters are operational
  # totals, not per-status keys, so they do not grow with traffic shape.
  module Log
    module_function

    def emit(event, **fields)
      payload = fields.map { |key, value| "#{key}=#{value}" }.join(' ')
      Rails.logger.info("[reboost] event=#{event} #{payload}")
      RedisConfiguration.with { |redis| redis.incr("reboost:metrics:#{event}") }
    rescue StandardError => error
      Rails.logger.warn("[reboost] metric failed event=#{event} error=#{error.class}")
    end
  end
end
