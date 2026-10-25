# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Owner-initiated rerun of an unsubscribe job that gave up. Only a failed
    # record with no automatic retry left moves; any other state, including a
    # failure the scheduler is still going to retry, is returned unchanged. The
    # owner therefore cannot reset the attempt limit while it is still running,
    # and a double click is safe.
    class SubscriptionDeletionRetry
      def call(user:, deletion_id:)
        raise Error, :not_found if user.nil?

        moved = false
        deletion = ApplicationRecord.transaction do
          found = ExternalSubscriptionDeletion.lock.find_by(id: deletion_id, user_id: user.id) || raise(Error, :not_found)
          if found.terminal_failed?
            now = Time.current
            found.update_columns(state: 'queued', attempt_count: 0, next_run_at: now + Unsubscribe::DISPATCH_GRACE, updated_at: now)
            moved = true
          end
          found
        end
        SubscriptionDeletionDispatch.enqueue(deletion.id) if moved
        deletion
      end
    end
  end
end
