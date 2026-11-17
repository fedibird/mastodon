# frozen_string_literal: true

# One inbox, one job: the Undo attempt runs, then the new Announce. This does
# not wait for the remote server to finish processing Undo, and a later Undo
# retry can still pass the Announce. That limit is recorded in the log.
class ActivityPub::OrderedReboostDeliveryWorker
  include Sidekiq::Worker
  include Payloadable

  sidekiq_options queue: 'push', retry: 8

  def perform(operation_id, inbox_url)
    operation = ReboostOperation.find_by(id: operation_id)
    return if operation.nil? || operation.undo_payload.blank?

    status = Status.find_by(id: operation.new_status_id)

    started = Time.current
    begin
      ActivityPub::DeliveryWorker.new.perform(operation.undo_payload, operation.account_id, inbox_url)
      Reboost::Log.emit('undo_attempt_ok', operation_id: operation.id, inbox: inbox_url)
    rescue StandardError => e
      Reboost::Log.emit('undo_attempt_failed', operation_id: operation.id, inbox: inbox_url, error: e.class)
      ActivityPub::DeliveryWorker.perform_async(operation.undo_payload, operation.account_id, inbox_url)
    end

    return if status.nil?

    ActivityPub::DeliveryWorker.new.perform(announce_payload(status, inbox_url), status.account_id, inbox_url)
    Reboost::Log.emit('announce_after_undo', operation_id: operation.id, inbox: inbox_url, milliseconds: ((Time.current - started) * 1000).round)
  end

  private

  def announce_payload(status, inbox_url)
    software = Node.find_domain(Addressable::URI.parse(inbox_url).normalized_host.to_s.downcase)&.software_name
    Oj.dump(serialize_payload(ActivityPub::ActivityPresenter.from_status(status), ActivityPub::ActivitySerializer, signer: status.account, software: software))
  end
end
