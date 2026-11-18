# frozen_string_literal: true

module Reboost
  # The due key is written before the operation becomes terminal. A retry can
  # enqueue the saved Undo without creating another wrapper.
  module UndoDelivery
    module_function

    def mark!(operation)
      return if operation.nil? || operation.undo_payload.blank?

      RedisConfiguration.with { |redis| redis.setex(key(operation), 6.hours.to_i, '1') }
    end

    def deliver!(operation)
      return if operation.nil? || operation.undo_payload.blank?
      return unless RedisConfiguration.with { |redis| redis.exists?(key(operation)) }

      Reboost::FederationWorker.perform_async(operation.id)
      RedisConfiguration.with { |redis| redis.del(key(operation)) }
    end

    def key(operation)
      "reboost:undo_due:#{operation.id}"
    end
  end
end
