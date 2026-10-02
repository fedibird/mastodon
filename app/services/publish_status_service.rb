# frozen_string_literal: true

# Side effects that make a status visible: mention delivery, timelines,
# federation, and background preview crawling.
#
# A Redis NX key makes a repeated call a no-op so a retried preparation
# job does not deliver twice. A crash after the key is set and before the
# enqueues leaves the status unpublished until an operator deletes
# statuses/:id/published and runs preparation again.
class PublishStatusService < BaseService
  include Redisable

  PUBLISHED_TTL = 7.days.to_i
  LINK_CRAWL_TTL = 15.minutes.to_i

  def call(status)
    return if status.nil? || !claim!(status)

    deliver_mentions!(status)
    distribute!(status)
    enqueue_link_crawl!(status)
  end

  private

  def claim!(status)
    redis.set(published_key(status), '1', nx: true, ex: PUBLISHED_TTL)
  end

  def published_key(status)
    "statuses/#{status.id}/published"
  end

  def deliver_mentions!(status)
    return if status.personal_visibility?

    ProcessMentionsService.new.record_and_deliver!(status)
  end

  def distribute!(status)
    if status.account.high_priority?
      PriorityDistributionWorker.perform_async(status.id)
    else
      DistributionWorker.perform_async(status.id)
    end

    ActivityPub::DistributionWorker.perform_async(status.id) unless status.personal_visibility?
  end

  def enqueue_link_crawl!(status)
    key = "statuses/#{status.id}/processing"
    redis.sadd(key, 'LinkCrawlWorker')
    ttl = redis.ttl(key)
    # Do not shorten a preparation marker that is still on this key.
    redis.expire(key, LINK_CRAWL_TTL) if ttl.negative? || ttl < LINK_CRAWL_TTL
    LinkCrawlWorker.perform_async(status.id)
  end
end
