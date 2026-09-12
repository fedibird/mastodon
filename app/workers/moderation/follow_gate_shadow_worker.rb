# frozen_string_literal: true

# Computes the (shadow) adaptive follow-gate decision off the hot path and logs
# what friction WOULD have been proposed. It never applies anything — this is
# pure observation for measuring firing frequency / timing / false positives
# before any real friction is ever wired in. Failure-tolerant.
class Moderation::FollowGateShadowWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: false

  def perform(account_id, context = {})
    account = Account.find_by(id: account_id)
    return if account.nil?

    decision = Moderation::AdaptiveFollowGateDecisionService.new.call(account, context: context)
    Rails.logger.info("[Moderation::FollowGateShadow] #{observation(decision).to_json}")
  rescue StandardError => e
    Rails.logger.warn("[Moderation::FollowGateShadowWorker] failed shadow observation: #{e.class}: #{e.message}")
    nil
  end

  private

  def observation(decision)
    {
      'shadow'             => true,
      'would_friction'     => decision['proposed_friction'],
      'policy_version'     => decision['policy_version'],
      'params_digest'      => decision['params_digest'],
      'subject_id'         => decision['subject_id'],
      'context'            => decision['context'],
      'matched_rule_count' => Array(decision['matched_rules']).size,
      'observed_at'        => Time.now.utc.iso8601,
    }
  end
end
