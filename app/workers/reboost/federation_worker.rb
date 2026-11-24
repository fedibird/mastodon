# frozen_string_literal: true

# Local replacement is already committed before this runs. Each shared inbox
# retries Undo and Announce together. Cancellation and failure stay those
# states: delivering a saved Undo records undo_enqueued_at and does not mark
# the operation completed. Waiting for every remote server is intentionally
# not done.
class Reboost::FederationWorker
  include Sidekiq::Worker
  include Payloadable
  include Redisable
  include Lockable

  sidekiq_options queue: 'push', retry: 8

  def perform(operation_id)
    with_redis_lock("reboost:federation:#{operation_id}") do
      operation = ReboostOperation.find_by(id: operation_id)
      return if operation.nil? || operation.state == 'completed'

      status = Status.find_by(id: operation.new_status_id)
      if undo_only?(operation, status)
        deliver_terminal_undo!(operation)
        return
      end

      undo_inboxes = Array(operation.undo_inboxes)
      announce_inboxes = announce_targets(status)
      announce_inboxes |= Relay.enabled.pluck(:inbox_url) if status.public_visibility?
      shared = undo_inboxes & announce_inboxes

      ActivityPub::OrderedReboostDeliveryWorker.push_bulk(shared) { |inbox| [operation.id, inbox] } if shared.any?
      deliver_undo(operation, undo_inboxes - shared)
      deliver_announce(status, announce_inboxes - undo_inboxes)

      queued_at = Time.current
      operation.update!(
        state: 'completed',
        completed_at: queued_at,
        undo_enqueued_at: operation.undo_payload.present? ? queued_at : operation.undo_enqueued_at
      )
      gap = operation.removal_finished_at ? (queued_at - operation.removal_finished_at).round(3) : nil
      Reboost::Log.emit('federated', operation_id: operation.id, gap_seconds: gap, shared_inboxes: shared.size, undo_only: (undo_inboxes - shared).size, announce_only: (announce_inboxes - undo_inboxes).size)
    end
  end

  private

  def undo_only?(operation, status)
    operation.state == 'cancelled' || operation.state == 'failed' || !status&.local?
  end

  def deliver_terminal_undo!(operation)
    deliver_undo(operation, Array(operation.undo_inboxes)) unless operation.undo_enqueued_at.present?

    now = Time.current
    attributes = {}
    attributes[:undo_enqueued_at] = now if operation.undo_payload.present? && operation.undo_enqueued_at.blank?
    if operation.state == 'federating'
      attributes[:state] = 'failed'
      attributes[:error_code] = operation.error_code.presence || 'missing_status'
      attributes[:completed_at] = now
    end
    operation.update!(attributes) if attributes.present?
  end

  def announce_targets(status)
    worker = ActivityPub::DistributionWorker.new
    worker.instance_variable_set(:@status, status)
    worker.instance_variable_set(:@account, status.account)
    worker.send(:inboxes)
  end

  def deliver_undo(operation, inboxes)
    return if operation.undo_payload.blank? || inboxes.empty?

    ActivityPub::DeliveryWorker.push_bulk(inboxes) do |inbox|
      [operation.undo_payload, operation.account_id, inbox]
    end
  end

  def deliver_announce(status, inboxes)
    return if inboxes.empty?

    ActivityPub::DeliveryWorker.push_bulk(inboxes) do |inbox|
      [announce_payload(status, inbox), status.account_id, inbox]
    end
  end

  def announce_payload(status, inbox)
    software = Node.find_domain(Addressable::URI.parse(inbox).normalized_host.to_s.downcase)&.software_name
    Oj.dump(serialize_payload(ActivityPub::ActivityPresenter.from_status(status), ActivityPub::ActivitySerializer, signer: status.account, software: software))
  end
end
