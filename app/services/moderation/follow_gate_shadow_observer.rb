# frozen_string_literal: true

# Shadow-mode entry point for the adaptive follow gate. It observes what friction
# the gate *would* propose for a follow attempt, without changing anything:
#
#   * Shadow only — it NEVER applies friction, blocks, delays, or alters the
#     follow. It just records a would-be decision for measurement.
#   * Off by default — gated behind the MODERATION_FOLLOW_GATE_SHADOW flag, so
#     merging this changes nothing until an operator turns it on to collect data.
#   * Failure-tolerant — any error is swallowed and logged; it can never break a
#     follow.
#   * Off the hot path — the evaluation (which reads the ledger) runs in a
#     background worker, so it does not add latency to the follow.
#
# The attempt context (mechanism, target locality/locked) is behaviour-neutral:
# it only routes which reversible friction the (shadow) decision would pick.
module Moderation
  class FollowGateShadowObserver
    class << self
      def observe(source_account:, target_account:, mechanism: nil)
        return unless enabled?
        return if source_account.nil? || target_account.nil?

        # Capture the attempt time now and pass it through, so the (async) shadow
        # decision is evaluated as of the follow attempt — not as of worker
        # execution. This prevents later follows/rejections/blocks from leaking
        # future events into a past attempt's decision during calibration.
        Moderation::FollowGateShadowWorker.perform_async(source_account.id, shadow_context(target_account, mechanism), Time.now.utc.iso8601)
      rescue StandardError => e
        Rails.logger.warn("[Moderation::FollowGateShadowObserver] failed to enqueue shadow observation: #{e.class}: #{e.message}")
        nil
      end

      def enabled?
        ENV['MODERATION_FOLLOW_GATE_SHADOW'].to_s == 'true'
      end

      private

      def shadow_context(target_account, mechanism)
        {
          'mechanism'       => mechanism,
          'target_locality' => target_account.local? ? 'local' : 'remote',
          'target_locked'   => target_account.locked? ? true : false,
        }
      end
    end
  end
end
