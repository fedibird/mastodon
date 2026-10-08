# frozen_string_literal: true

class PostingContext::RevalidateGroupEvidenceWorker
  include Sidekiq::Worker

  # Short enough that a live worker refreshes the 10 minute lease many times
  # during actor and affiliation fetches. A dead worker stops renewing, and
  # the lease can expire.
  HEARTBEAT_INTERVAL = 30

  sidekiq_options queue: 'pull', retry: 3

  def perform(account_id, request_id)
    registry = PostingContext::RevalidationRegistry.new
    heartbeat = nil
    return unless registry.mark_running!(account_id, request_id)

    heartbeat = start_heartbeat(registry, account_id, request_id)
    result = evidence_for(registry, account_id, request_id)
    return if result.nil?
    return unless registry.renew!(account_id, request_id)

    registry.finish!(account_id, request_id, result)
  rescue StandardError
    registry&.finish!(account_id, request_id, failed_result)
    raise
  ensure
    stop_heartbeat(heartbeat)
  end

  private

  def evidence_for(registry, account_id, request_id)
    account = Account.find_by(id: account_id)
    return failed_result unless account && PostingContext::RevalidationEligibility.eligible?(account)

    PostingContext::RevalidateGroupEvidenceService.new.call(
      account,
      on_step: -> { registry.renew!(account_id, request_id) },
      request_id: request_id
    )
  end

  def start_heartbeat(registry, account_id, request_id)
    done = Queue.new
    thread = Thread.new do
      loop do
        break if done.pop(timeout: self.class::HEARTBEAT_INTERVAL)
        break unless registry.extend_lease!(account_id, request_id)
      end
    end
    { done: done, thread: thread }
  end

  def stop_heartbeat(heartbeat)
    return unless heartbeat

    heartbeat[:done] << true
    heartbeat[:thread].join(2)
  end

  def failed_result
    PostingContext::RevalidateGroupEvidenceService::Result.new(state: 'failed', actor: 'failed', affiliations: 'failed')
  end
end
