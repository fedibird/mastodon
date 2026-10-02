# frozen_string_literal: true

# Decides whether a status may be published, and tracks that wait on the
# existing statuses/:id/processing set. This class does not perform HTTP.
class StatusPublishPreparationService < BaseService
  include Redisable

  MARKER = 'StatusPublishPreparationWorker'
  # Long enough to cover ExponentialBackoff before the last of 6 retries.
  PROCESSING_TTL = 6.hours.to_i

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

  def clear!(status_or_id)
    key = processing_key(id_of(status_or_id))
    redis.srem(key, MARKER)
    redis.del(key) if redis.scard(key) <= 0
  end

  private

  def redirect_target?(url)
    host = Addressable::URI.parse(url).host
    host.present? && FetchLinkCardService.redirect_target_host?(host)
  rescue Addressable::URI::InvalidURIError, ArgumentError
    false
  end

  def processing_key(status_id)
    "statuses/#{status_id}/processing"
  end

  def id_of(status_or_id)
    status_or_id.respond_to?(:id) ? status_or_id.id : status_or_id
  end
end
