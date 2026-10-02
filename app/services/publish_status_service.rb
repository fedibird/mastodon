# frozen_string_literal: true

# Side effects that make a status visible: mention delivery, timelines,
# and federation. Preview crawling is a later best-effort step.
#
# statuses/<id>/published is written only after mention delivery and
# distribution enqueue return. A failure before that leaves the key
# unset so the caller can retry. Enqueues that already succeeded may
# run again on that retry. A link-crawl enqueue failure does not.

class PublishStatusService < BaseService
  include Redisable
  include Lockable

  class NotPublished < StandardError; end

  PUBLISHED_TTL = 7.days.to_i

  def call(status)
    return if status.nil? || published?(status)

    with_redis_lock("publish-status:#{status.id}") do
      return if published?(status)

      deliver_mentions!(status)
      distribute!(status)
      mark_published!(status)
      enqueue_link_crawl_best_effort!(status)
    end
  end

  def published?(status)
    return false if status.nil?

    redis.exists?(published_key(status))
  end

  private

  def mark_published!(status)
    redis.set(published_key(status), '1', ex: PUBLISHED_TTL)
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

  def enqueue_link_crawl_best_effort!(status)
    preparation = StatusPublishPreparationService.new
    preparation.add_link_crawl!(status)
    LinkCrawlWorker.perform_async(status.id)
  rescue StandardError => e
    StatusPublishPreparationService.new.remove_link_crawl!(status)
    Rails.logger.error("[PublishStatus] link crawl enqueue failed status=#{status.id}: #{e.class}: #{e.message}")
  end
end
