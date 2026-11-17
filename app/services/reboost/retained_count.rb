# frozen_string_literal: true

module Reboost
  # A reported wrapper is kept, so its reblogs_count change is recorded once.
  module RetainedCount
    module_function

    def release!(original, wrapper)
      key = "reboost:reblog_counted_out:#{wrapper.id}"
      claimed = RedisConfiguration.with { |redis| redis.set(key, '1', nx: true) }
      return unless claimed

      original.association(:status_stat).reset
      original.decrement_count!(:reblogs_count)
    rescue StandardError
      RedisConfiguration.with { |redis| redis.del(key) }
      raise
    end
  end
end
