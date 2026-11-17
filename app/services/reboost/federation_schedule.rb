# frozen_string_literal: true

module Reboost
  # Records that a federation job was queued, and queues it again when a
  # same-key retry finds a federating operation that never got that far.
  module FederationSchedule
    def enqueue_federation!(operation)
      with_redis_lock("reboost:federation_enqueue:#{operation.id}") do
        return if federation_enqueued?(operation)

        Reboost::FederationWorker.perform_in(Reboost::FEDERATION_GAP, operation.id)
        RedisConfiguration.with { |redis| redis.setex(federation_enqueued_key(operation), 6.hours.to_i, '1') }
      end
    end

    def ensure_federating!(status)
      return if status.nil?

      operation = ReboostOperation.where(account_id: account.id, new_status_id: status.id, state: 'federating').order(id: :desc).first
      enqueue_federation!(operation) if operation && !federation_enqueued?(operation)
    end

    def federation_enqueued?(operation)
      RedisConfiguration.with { |redis| redis.exists?(federation_enqueued_key(operation)) }
    end

    def federation_enqueued_key(operation)
      "reboost:federation_enqueued:#{operation.id}"
    end
  end
end
