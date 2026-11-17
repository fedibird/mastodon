# frozen_string_literal: true

# One inbox, one job. Undo is delivered, then the new Announce, and a failure
# raises so Sidekiq retries that same inbox from Undo. Other inboxes have
# their own jobs. Announce is sent only when the replacement is still the
# live local wrapper.
class ActivityPub::OrderedReboostDeliveryWorker
  class UndoNotDelivered < StandardError; end

  include Sidekiq::Worker
  include Payloadable

  sidekiq_options queue: 'push', retry: 8

  def perform(operation_id, inbox_url)
    operation = ReboostOperation.find_by(id: operation_id)
    return if operation.nil? || operation.undo_payload.blank?

    started = Time.current
    delivered = ActivityPub::DeliveryWorker.new.perform(operation.undo_payload, operation.account_id, inbox_url)
    raise UndoNotDelivered, inbox_url unless delivered

    Reboost::Log.emit('undo_attempt_ok', operation_id: operation.id, inbox: inbox_url)

    operation.reload
    status = Status.find_by(id: operation.new_status_id)
    return if operation.state == 'cancelled' || status.nil? || !status.local?

    ActivityPub::DeliveryWorker.new.perform(announce_payload(status, inbox_url), status.account_id, inbox_url)
    Reboost::Log.emit('announce_after_undo', operation_id: operation.id, inbox: inbox_url, milliseconds: ((Time.current - started) * 1000).round)
  end

  private

  def announce_payload(status, inbox_url)
    software = Node.find_domain(Addressable::URI.parse(inbox_url).normalized_host.to_s.downcase)&.software_name
    Oj.dump(serialize_payload(ActivityPub::ActivityPresenter.from_status(status), ActivityPub::ActivitySerializer, signer: status.account, software: software))
  end
end
