# frozen_string_literal: true

class LinkCrawlWorker
  include Sidekiq::Worker
  include Redisable

  sidekiq_options queue: 'pull', retry: 0, lock: :until_executed

  def perform(status_id)
    FetchLinkCardService.new.call(Status.find(status_id))
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordNotUnique
    true
  ensure
    done_process(status_id)
  end

  private

  def done_process(status_id)
    redis.srem("statuses/#{status_id}/processing", 'LinkCrawlWorker')
    redis.del("statuses/#{status_id}/processing") if redis.scard("statuses/#{status_id}/processing") <= 0
    StatusStat.find_by(status_id: status_id)&.touch || StatusStat.create!(status_id: status_id)
  end
end
