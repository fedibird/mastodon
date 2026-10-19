# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Fetch failures use the subscription retry ceiling. A bounded import backlog
    # does not: item attempt_count and next_attempt_at decide the next page.
    # Shared source rows hold neither.
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
        open = open_failures(subscription)
        isolated = isolated_failures(subscription).count
        due = open.where('next_attempt_at IS NULL OR next_attempt_at <= ?', Time.current).count
        earliest = open.where('next_attempt_at > ?', Time.current).minimum(:next_attempt_at)
        outstanding = [open.count + isolated, result.failed.to_i].max

        if open.none? && result.failed.to_i.zero?
          if isolated.zero?
            synced!(subscription)
          else
            parked!(subscription, isolated)
          end
          return
        end

        # One eligible page per run. A later page that is already due is scheduled
        # immediately, without counting toward the fetch-failure ceiling. A page
        # that is waiting on next_attempt_at uses that time as the subscription
        # deadline so the scheduler does not fetch early.
        subscription.update!(
          state: 'active',
          last_error_code: 'import_failed',
          last_error_at: Time.current,
          checked_at: Time.current,
          next_retry_at: due.positive? ? 1.second.ago : earliest,
          retry_count: 0,
          failed_item_count: outstanding
        )
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
