# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Machine-readable progress of one unsubscribe for the owner's REST API.
    # Counters, fixed state words, and a fixed error code only: no feed URL,
    # title, item text, token, or exception message.
    module SubscriptionDeletionPayload
      module_function

      def call(deletion)
        {
          id: deletion.id.to_s,
          subscription_id: deletion.external_subscription_id.to_s,
          state: deletion.state,
          preparing: deletion.preparing?,
          total: deletion.total_count,
          deleted: deletion.deleted_count,
          remaining: deletion.remaining,
          percent: deletion.percent,
          eta_seconds: deletion.eta_seconds,
          retryable: deletion.retryable?,
          last_error_code: deletion.failed? ? deletion.last_error_code : nil,
          requested_at: deletion.requested_at,
          started_at: deletion.started_at,
          finished_at: deletion.finished_at,
          url: "/api/v1/external_bridge/rss/subscription_deletions/#{deletion.id}",
        }
      end
    end
  end
end
