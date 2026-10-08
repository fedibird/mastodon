# frozen_string_literal: true

class PostingContext::RevalidateGroupEvidenceWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: 3

  def perform(account_id, request_id)
    registry = PostingContext::RevalidationRegistry.new
    return unless registry.mark_running!(account_id, request_id)

    result = evidence_for(Account.find_by(id: account_id))
    return unless registry.renew!(account_id, request_id)

    registry.finish!(account_id, request_id, result)
  rescue StandardError
    registry&.finish!(account_id, request_id, failed_result)
    raise
  end

  private

  def evidence_for(account)
    return failed_result unless account && PostingContext::RevalidationEligibility.eligible?(account)

    PostingContext::RevalidateGroupEvidenceService.new.call(account)
  end

  def failed_result
    PostingContext::RevalidateGroupEvidenceService::Result.new(state: 'failed', actor: 'failed', affiliations: 'failed')
  end
end
