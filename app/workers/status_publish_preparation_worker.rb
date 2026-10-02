# frozen_string_literal: true

# Resolves redirect semantics, then publishes. Preview cards are not part
# of this wait. Temporary failures retry and keep the processing marker.
# Permanent failure and exhausted retries log the status and URLs and do
# not publish.
class StatusPublishPreparationWorker
  include Sidekiq::Worker
  include ExponentialBackoff
  include Redisable
  include Lockable

  sidekiq_options queue: 'pull', retry: 6, lock: :until_executed

  sidekiq_retries_exhausted do |msg, exception|
    status_id = msg['args']&.first
    status = Status.find_by(id: status_id)
    urls = status ? StatusPublishPreparationService.new.unresolved_redirect_urls(status) : []
    error_class = exception&.class || msg['error_class']
    error_message = exception&.message || msg['error_message']
    Rails.logger.error("[StatusPublishPreparation] retries exhausted status=#{status_id} urls=#{urls.join(' ')} error=#{error_class}: #{error_message}")
    StatusPublishPreparationService.new.clear!(status_id)
  end

  def perform(status_id)
    status = Status.find(status_id)
    preparation.mark!(status)

    with_redis_lock("publish-prepare:#{status.id}") do
      prepare_and_publish!(status)
    end
  rescue ActiveRecord::RecordNotFound
    preparation.clear!(status_id)
    true
  rescue StandardError
    preparation.refresh!(status_id)
    raise
  end

  private

  def prepare_and_publish!(status)
    temporary = resolve_all!(status)
    remaining = preparation.unresolved_redirect_urls(status)

    if remaining.any?
      raise temporary if temporary

      leave_unpublished!(status, remaining)
      return
    end

    touch_status_stat!(status)
    PublishStatusService.new.call(status)
    preparation.clear!(status)
  end

  def resolve_all!(status)
    temporary = nil

    preparation.unresolved_redirect_urls(status).each do |url|
      ResolveRedirectLinkService.new.call(url)
    rescue ResolveRedirectLinkService::TemporaryFailure => e
      temporary ||= e
      log_failure('temporary failure', status, e)
    rescue ResolveRedirectLinkService::PermanentFailure => e
      log_failure('permanent failure', status, e)
    end

    temporary
  end

  def leave_unpublished!(status, urls)
    Rails.logger.error("[StatusPublishPreparation] unpublished status=#{status.id} urls=#{urls.join(' ')} error=UnresolvedRedirect: redirect semantics were not resolved")
    preparation.clear!(status)
  end

  def log_failure(kind, status, error)
    Rails.logger.error("[StatusPublishPreparation] #{kind} status=#{status.id} url=#{error.url} error=#{error.class}: #{error.message}")
  end

  def touch_status_stat!(status)
    StatusStat.find_by(status_id: status.id)&.touch || StatusStat.create!(status_id: status.id)
  end

  def preparation
    StatusPublishPreparationService.new
  end
end
