# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Pushes SubscriptionDeletionWorker for one record. Never raises: the
    # record's next_run_at is the durable outbox, and the recovery scheduler
    # pushes again when this push is refused or lost.
    module SubscriptionDeletionDispatch
      module_function

      def enqueue(deletion_id, delay: nil)
        jid = if delay
                SubscriptionDeletionWorker.perform_in(delay, deletion_id)
              else
                SubscriptionDeletionWorker.perform_async(deletion_id)
              end
        jid.present?
      rescue StandardError => e
        SubscriptionDeletionLog.emit('enqueue_failed', deletion_id: deletion_id, error_class: e.class)
        false
      end
    end
  end
end
