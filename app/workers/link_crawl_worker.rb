# frozen_string_literal: true

class LinkCrawlWorker
  include Sidekiq::Worker
  include Redisable

  sidekiq_options queue: 'pull', retry: 0, lock: :until_executed

  def perform(status_id)
    status = Status.find(status_id)
    return if ExternalBridge::ProjectionPrivacy.private_status?(status)

    FetchLinkCardService.new.call(status)
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordNotUnique, Mastodon::RaceConditionError
    true
  ensure
    done_process(status_id) unless ExternalBridge::ProjectionPrivacy.private_id?(status_id)
  end

  private

  def done_process(status_id)
    redis.srem("statuses/#{status_id}/processing", 'LinkCrawlWorker')
    redis.del("statuses/#{status_id}/processing") if redis.scard("statuses/#{status_id}/processing") <= 0
    StatusStat.find_by(status_id: status_id)&.touch || StatusStat.create!(status_id: status_id)
  end
end
