# frozen_string_literal: true

class DistributionWorker
  include Sidekiq::Worker
  include Redisable
  include Lockable

  def perform(status_id, options = {})
    with_redis_lock("distribute:#{status_id}") do
      status = Status.find(status_id)
      return if ExternalBridge::ProjectionPrivacy.private_status?(status)

      FanOutOnWriteService.new.call(status, **options.symbolize_keys)
    end
  rescue ActiveRecord::RecordNotFound
    true
  end
end
