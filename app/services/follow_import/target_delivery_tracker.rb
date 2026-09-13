# frozen_string_literal: true

# Delivery-tracking handler for follow-import targets, invoked generically by
# ActivityPub::DeliveryTracking. It records only delivery bookkeeping — HTTP
# delivery of the Follow succeeded (awaiting an Accept/Reject), or delivery
# ultimately failed after Sidekiq retries were exhausted. It never applies
# friction or touches the moderation ledger, and delivery success is not follow
# acceptance.
module FollowImport
  class TargetDeliveryTracker
    class << self
      def delivered(target_id)
        target = FollowImportTarget.find_by(id: target_id)
        return if target.nil?

        transitions.mark_awaiting_response(
          target,
          follow_request_uri: target.follow_request_uri,
          response_deadline_at: FollowImport::ExecutionPolicy.response_deadline_at
        )
      end

      # Only called from DeliveryWorker's retries-exhausted hook (a terminal
      # delivery failure), never on an intermediate retry.
      def failed(target_id)
        target = FollowImportTarget.find_by(id: target_id)
        return if target.nil?

        transitions.mark_delivery_failed(target, failure_code: 'delivery_retries_exhausted')
      end

      private

      def transitions
        FollowImport::TargetTransitionService.new
      end
    end
  end
end
