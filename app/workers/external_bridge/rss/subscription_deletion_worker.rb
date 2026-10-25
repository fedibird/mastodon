# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Removes the data of one accepted unsubscribe. It is not gated by the
    # ExternalBridge feature flags: a deletion that has started always finishes,
    # while new imports stay stopped by the subscription fence.
    #
    # No Sidekiq retry and no unique lock. The runner records its own failure
    # (the owner sees it and the recovery scheduler backs off), and a run that
    # used up its budget queues the next one itself, which a held unique lock
    # would refuse. Two workers on one record take turns on its row lock.
    class SubscriptionDeletionWorker
      include Sidekiq::Worker

      CONTINUE_DELAY = 1.second

      sidekiq_options queue: 'pull', retry: 0

      def perform(deletion_id)
        outcome = SubscriptionDeletionRunner.new.call(deletion_id.to_i)
        case outcome
        when :continue
          SubscriptionDeletionDispatch.enqueue(deletion_id.to_i, delay: CONTINUE_DELAY)
        when :effects_pending
          # The rows are gone. This only retries the stream/cache/search
          # outbox. next_run_at is the same delay, so a lost push is recovered
          # by the scheduler. It does not count as a failed attempt.
          SubscriptionDeletionDispatch.enqueue(deletion_id.to_i, delay: SubscriptionDeletionRunner::EFFECTS_RETRY)
        end
      end
    end
  end
end
