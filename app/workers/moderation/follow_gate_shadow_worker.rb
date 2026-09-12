# frozen_string_literal: true

# Computes the (shadow) adaptive follow-gate decision off the hot path and logs
# what friction WOULD have been proposed. It never applies anything — this is
# pure observation for measuring firing frequency / timing / false positives
# before any real friction is ever wired in. Failure-tolerant.
#
# The decision is evaluated as of +attempted_at+ (the follow attempt time), so
# events that happen between the attempt and this worker running are not leaked
# into the attempt's decision.
#
# KNOWN LIMITATION / TODO: the observation is keyed by account_id, so if the
# account is deleted before this runs the observation is lost. Since the ledger
# keeps a ModerationSubject after account deletion, higher-risk subjects (more
# likely to be actioned/deleted) would be dropped disproportionately — a
# selection bias. A future revision should evaluate by ModerationSubject id so
# shadow data survives account deletion.
class Moderation::FollowGateShadowWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: false

  def perform(account_id, context = {}, attempted_at = nil)
    account = Account.find_by(id: account_id)
    return if account.nil?

    now      = parse_time(attempted_at)
    decision = Moderation::AdaptiveFollowGateDecisionService.new.call(account, context: context, now: now)
    Rails.logger.info("[Moderation::FollowGateShadow] #{observation(decision, now).to_json}")
  rescue StandardError => e
    Rails.logger.warn("[Moderation::FollowGateShadowWorker] failed shadow observation: #{e.class}: #{e.message}")
    nil
  end

  private

  def parse_time(value)
    value.present? ? Time.iso8601(value) : Time.now.utc
  rescue ArgumentError
    Time.now.utc
  end

  def observation(decision, attempted_at)
    {
      'shadow'             => true,
      'would_friction'     => decision['proposed_friction'],
      'policy_version'     => decision['policy_version'],
      'params_digest'      => decision['params_digest'],
      'subject_id'         => decision['subject_id'],
      'context'            => decision['context'],
      'matched_rule_count' => Array(decision['matched_rules']).size,
      'attempted_at'       => attempted_at.utc.iso8601,
      'observed_at'        => Time.now.utc.iso8601,
    }
  end
end
