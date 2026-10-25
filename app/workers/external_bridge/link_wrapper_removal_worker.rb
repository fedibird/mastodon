# frozen_string_literal: true

module ExternalBridge
  # Removes the wrapper of an ended E4 link share (the Undo for an announced
  # one). It is the only worker that records `removal_acknowledged_at`;
  # RemovalWorker stays what Mastodon wrote, so an explicit request such as
  # `immediate: true` for the same status (an admin, a report decision) is never
  # swallowed by an E4 shortcut.
  #
  # Exclusion is a lease on the boost row, not a database session. A job first
  # claims the row with one conditional UPDATE (share ended, not acknowledged,
  # no live lease) and writes its own token; it then runs RemoveStatusService and
  # acknowledges with a second UPDATE that matches the token. Each statement
  # stands alone, so nothing depends on both reaching the same PostgreSQL
  # backend: PgBouncer in transaction pooling mode (where a session advisory lock
  # would be granted twice or leak) and a direct connection behave the same.
  # No transaction is held while RemoveStatusService runs.
  #
  # - A second job that arrives while the lease is live does nothing and is not
  #   retried by Sidekiq; if the first never acknowledges, its lease expires
  #   after LEASE and the recovery scan pushes again.
  # - A job that arrives after the acknowledgement does nothing.
  # - A job that fails gives the lease back before it raises.
  # - A job that dies leaves the lease to expire. Another job may then take over
  #   while a slow first job is still running (RemoveStatusService normally takes
  #   seconds; LEASE is minutes). The first job's acknowledgement then matches no
  #   token and changes nothing.
  #
  # What is not guaranteed. Delivery is at least once: a job that dies after
  # RemoveStatusService returned and before its acknowledgement commits, or one
  # that outlives its lease, lets the next job hand the Undo to delivery again.
  # ActivityPub receivers treat a repeated Undo of an activity they already undid
  # as a no-op. Acknowledged means the Undo reached the delivery queue, not that
  # a remote server received it.
  class LinkWrapperRemovalWorker
    include Sidekiq::Worker

    LEASE = 5.minutes

    def perform(status_id)
      token = SecureRandom.hex(16)
      return false unless LinkSharing::Retire.claim_removal!(status_id, token, LEASE)

      begin
        RemoveStatusService.new.call(Status.include_expired.with_discarded.find(status_id))
        LinkSharing::Checkpoints.fire(:removal_before_acknowledge, status_id)
        LinkSharing::Retire.acknowledge_removal!(token)
      rescue ActiveRecord::RecordNotFound
        LinkSharing::Retire.release_removal!(token)
        true
      rescue StandardError
        LinkSharing::Retire.release_removal!(token)
        raise
      end
    end
  end
end
