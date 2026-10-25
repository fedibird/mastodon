# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Owner-initiated rerun of a failed unsubscribe job. Only a failed record
    # moves; any other state is returned unchanged, so a double click is safe.
    class SubscriptionDeletionRetry
      def call(user:, deletion_id:)
        raise Error, :not_found if user.nil?

        deletion = ApplicationRecord.transaction do
          found = ExternalSubscriptionDeletion.lock.find_by(id: deletion_id, user_id: user.id) || raise(Error, :not_found)
          if found.failed?
            now = Time.current
            found.update_columns(state: 'queued', attempt_count: 0, next_run_at: now + Unsubscribe::DISPATCH_GRACE, updated_at: now)
          end
          found
        end
        SubscriptionDeletionDispatch.enqueue(deletion.id) if deletion.queued?
        deletion
      end
    end
  end
end
