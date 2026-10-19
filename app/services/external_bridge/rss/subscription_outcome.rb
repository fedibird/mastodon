# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Subscription rows hold retry and import errors. Shared source rows do not.
    module SubscriptionOutcome
      module_function

      def fetch_failure!(subscription, code)
        if RetryPolicy.terminal?(code)
          terminal!(subscription, code)
        else
          retry!(subscription, code)
        end
      end

      def reconcile!(subscription, result)
        open_count = open_failures(subscription).count
        open_count = result.failed if open_count < result.failed.to_i
        isolated = isolated_failures(subscription).count
        if open_count.zero?
          if isolated.zero?
            synced!(subscription)
          else
            parked!(subscription, isolated)
          end
        else
          retry!(subscription, 'import_failed', failed_item_count: open_count + isolated)
        end
      end

      def terminal!(subscription, code)
        subscription.update!(
          state: 'error',
          last_error_code: code.to_s,
          last_error_at: Time.current,
          checked_at: Time.current,
          next_retry_at: nil,
          retry_count: 0
        )
      end

      def retry!(subscription, code, failed_item_count: nil)
        count = subscription.retry_count.to_i + 1
        failed = failed_item_count.nil? ? subscription.failed_item_count : failed_item_count
        if count >= RetryPolicy::CEILING
          subscription.update!(
            state: 'error',
            last_error_code: code.to_s,
            last_error_at: Time.current,
            checked_at: Time.current,
            next_retry_at: nil,
            retry_count: count,
            failed_item_count: failed
          )
        else
          subscription.update!(
            state: 'active',
            last_error_code: code.to_s,
            last_error_at: Time.current,
            checked_at: Time.current,
            next_retry_at: Time.current + RetryPolicy.delay(count, subscription.id),
            retry_count: count,
            failed_item_count: failed
          )
        end
      end

      def synced!(subscription)
        ExternalProjectionFailure.where(external_subscription_id: subscription.id).delete_all
        subscription.update!(
          state: 'active',
          last_error_code: nil,
          last_error_at: nil,
          checked_at: Time.current,
          next_retry_at: nil,
          retry_count: 0,
          failed_item_count: 0
        )
      end

      # Items that reached the per-item ceiling stay recorded so resume can
      # reset them. They do not keep advancing this subscription's retry_count.
      def parked!(subscription, isolated)
        subscription.update!(
          state: 'active',
          last_error_code: 'import_failed',
          last_error_at: Time.current,
          checked_at: Time.current,
          next_retry_at: nil,
          retry_count: 0,
          failed_item_count: isolated
        )
      end

      def open_failures(subscription)
        ExternalProjectionFailure.where(external_subscription_id: subscription.id)
                                 .where('attempt_count < ?', Limits::ITEM_ATTEMPT_CEILING)
      end

      def isolated_failures(subscription)
        ExternalProjectionFailure.where(external_subscription_id: subscription.id)
                                 .where('attempt_count >= ?', Limits::ITEM_ATTEMPT_CEILING)
      end
    end
  end
end
