# frozen_string_literal: true

module ExternalBridge
  # Removes the wrapper of an ended E4 link share (the Undo for an announced
  # one). It is the only worker that records `removal_acknowledged_at`;
  # RemovalWorker stays what Mastodon wrote, so an explicit request such as
  # `immediate: true` for the same status (an admin, a report decision) is never
  # swallowed by an E4 shortcut.
  #
  # Exclusion. The check of the acknowledgement, RemoveStatusService, and the
  # acknowledgement run under one PostgreSQL session advisory lock per wrapper.
  # A second job that arrives while the first is working does nothing (the first
  # will acknowledge, or the recovery pushes again later); one that arrives
  # after sees the acknowledgement and does nothing. The lock belongs to the
  # connection, so a worker that dies releases it at once. It is not
  # RemoveStatusService's own Redis lock (`distribute:<id>`), which is released
  # when the service returns and expires on its own after 15 minutes.
  #
  # What is not guaranteed. Delivery is at least once: a crash between the
  # return of RemoveStatusService and the commit of the acknowledgement is the
  # one window in which the recovery pushes again and the Undo can be handed to
  # delivery a second time. ActivityPub receivers treat a repeated Undo of an
  # activity they already undid as a no-op. Acknowledged means the Undo reached
  # the delivery queue, not that a remote server received it.
  class LinkWrapperRemovalWorker
    include Sidekiq::Worker

    LOCK_NAMESPACE = 'external_bridge_wrapper_removal'

    def perform(status_id)
      with_wrapper_lock(status_id) do
        next if LinkSharing::Retire.removal_acknowledged?(status_id)

        RemoveStatusService.new.call(Status.include_expired.with_discarded.find(status_id))
        LinkSharing::Checkpoints.fire(:removal_before_acknowledge, status_id)
        LinkSharing::Retire.acknowledge_removal!(status_id)
      end
    rescue ActiveRecord::RecordNotFound
      true
    end

    private

    def with_wrapper_lock(status_id)
      connection = ActiveRecord::Base.connection
      key = connection.quote("#{LOCK_NAMESPACE}:#{status_id}")
      locked = connection.select_value("SELECT pg_try_advisory_lock(hashtextextended(#{key}, 0))")
      locked = locked == true || locked.to_s == 't'
      return false unless locked

      yield
    ensure
      connection.execute("SELECT pg_advisory_unlock(hashtextextended(#{key}, 0))") if locked
    end
  end
end
