# frozen_string_literal: true

class RedirectLinkResolveWorker
  include Sidekiq::Worker
  include ExponentialBackoff
  include Redisable

  sidekiq_options queue: 'pull', retry: 3, lock: :until_executed

  sidekiq_retries_exhausted do |msg|
    url, status_id = msg['args']
    Sidekiq.logger.error("Processing redirect link resolver #{url} in #{status_id} failed with #{msg['error_message']}")
    new.__send__(:done_process, url, status_id) if url.present? && status_id.present?
  end

  def perform(url, status_id)
    ResolveRedirectLinkService.new.call(url)
    done_process(url, status_id)
  rescue ResolveRedirectLinkService::TemporaryFailure, ResolveRedirectLinkService::PermanentFailure
    # Preview crawling stays fail-open. Publish preparation uses the same
    # resolver but does not publish when resolution fails.
    done_process(url, status_id)
    true
  end

  private

  def done_process(url, status_id)
    redis.srem("statuses/#{status_id}/processing", "RedirectLinkResolveWorker:#{url}")
    redis.del("statuses/#{status_id}/processing") if redis.scard("statuses/#{status_id}/processing") <= 0
    StatusStat.find_by(status_id: status_id)&.touch || StatusStat.create!(status_id: status_id)
  end
end
