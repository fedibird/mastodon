# frozen_string_literal: true

# Decides whether a status may be published, and tracks that wait on the
# existing statuses/:id/processing set. This class does not perform HTTP.
class StatusPublishPreparationService < BaseService
  include Redisable

  MARKER = 'StatusPublishPreparationWorker'
  LINK_CRAWL_MARKER = 'LinkCrawlWorker'
  # Long enough to cover ExponentialBackoff before the last of 6 retries.
  PROCESSING_TTL = 6.hours.to_i
  LINK_CRAWL_TTL = 15.minutes.to_i

  def unresolved_redirect_urls(status)
    return [] if status.nil?

    redirect_urls = FetchLinkCardService.extract_urls(status).select { |url| redirect_target?(url) }
    return [] if redirect_urls.empty?

    known = RedirectLink.where(url: redirect_urls).pluck(:url)
    redirect_urls - known
  end

  def mark!(status)
    redis.sadd(processing_key(status.id), MARKER)
    redis.expire(processing_key(status.id), PROCESSING_TTL)
  end

  def refresh!(status_or_id)
    key = processing_key(id_of(status_or_id))
    return unless redis.sismember(key, MARKER)

    redis.expire(key, PROCESSING_TTL)
  end

  def marked?(status_or_id)
    redis.sismember(processing_key(id_of(status_or_id)), MARKER)
  end

  def add_link_crawl!(status)
    key = processing_key(status.id)
    redis.sadd(key, LINK_CRAWL_MARKER)
    ttl = redis.ttl(key)
    # Leave a longer marker, such as redirect preparation, on its own TTL.
    redis.expire(key, LINK_CRAWL_TTL) if ttl.negative? || ttl < LINK_CRAWL_TTL
  end

  # Drops only the preview-crawl member. Other processing members stay.
  def remove_link_crawl!(status_or_id)
    key = processing_key(id_of(status_or_id))
    redis.srem(key, LINK_CRAWL_MARKER)
    redis.del(key) if redis.scard(key) <= 0
  end

  def clear!(status_or_id)
    key = processing_key(id_of(status_or_id))
    redis.srem(key, MARKER)
    adjust_processing_ttl!(key)
  end

  private

  def redirect_target?(url)
    host = Addressable::URI.parse(url).host
    host.present? && FetchLinkCardService.redirect_target_host?(host)
  rescue Addressable::URI::InvalidURIError, ArgumentError
    false
  end

  def adjust_processing_ttl!(key)
    members = redis.smembers(key)
    if members.empty?
      redis.del(key)
    elsif members == [LINK_CRAWL_MARKER]
      redis.expire(key, LINK_CRAWL_TTL)
    end
  end

  def processing_key(status_id)
    "statuses/#{status_id}/processing"
  end

  def id_of(status_or_id)
    status_or_id.respond_to?(:id) ? status_or_id.id : status_or_id
  end
end
