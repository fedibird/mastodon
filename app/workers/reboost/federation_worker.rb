# frozen_string_literal: true

# Local replacement is already committed before this runs. Each shared inbox
# retries Undo and Announce together. A cancelled operation, or one whose new
# wrapper is gone, sends only the saved Undo. Waiting for every remote server
# is intentionally not done.
class Reboost::FederationWorker
  include Sidekiq::Worker
  include Payloadable

  sidekiq_options queue: 'push', retry: 8

  def perform(operation_id)
    operation = ReboostOperation.find_by(id: operation_id)
    return if operation.nil? || operation.state == 'completed'

    status = Status.find_by(id: operation.new_status_id)
    if operation.state == 'cancelled' || !status&.local?
      # The replacement can be unreblogged during the gap. The old Undo was
      # saved before that wrapper existed, so it still has to go out.
      deliver_undo(operation, Array(operation.undo_inboxes))
      if operation.undo_payload.present?
        operation.update!(state: 'completed', completed_at: Time.current)
      else
        operation.fail!('missing_status')
      end
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
    operation.update!(state: 'completed', completed_at: queued_at)
    gap = operation.removal_finished_at ? (queued_at - operation.removal_finished_at).round(3) : nil
    Reboost::Log.emit('federated', operation_id: operation.id, gap_seconds: gap, shared_inboxes: shared.size, undo_only: (undo_inboxes - shared).size, announce_only: (announce_inboxes - undo_inboxes).size)
  end

  private

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
