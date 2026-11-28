# frozen_string_literal: true

module Reboost
  # The Undo belongs to operation.old_status_id. A later boost of the same
  # post does not cancel that delivery. The decision is stored with the
  # terminal update: a payload that remains is still owed, and a cleared
  # payload is not sent again when that old boost is removed later.
  module UndoDelivery
    module_function

    def settle!(operation)
      return if operation.nil?

      operation.reload
      enqueue!(operation)
    end

    # Merged into the same update that marks the operation terminal.
    def terminal_undo_attributes(operation)
      return {} if operation.nil? || operation.undo_enqueued_at.present? || operation.undo_payload.blank?
      return {} if due?(operation)

      { undo_payload: nil, undo_inboxes: [] }
    end

    # A recorded id is due only when that status is gone or discarded.
    # A payload with no recorded id is due when this actor has no boost left.
    def due?(operation)
      return false if operation.nil? || operation.undo_payload.blank? || operation.undo_enqueued_at.present?
      return removed_wrapper?(operation) if operation.old_status_id.present?

      !active_wrapper?(operation)
    end

    def enqueue!(operation)
      return if operation.nil? || operation.undo_payload.blank? || operation.undo_enqueued_at.present?

      Reboost::FederationWorker.perform_async(operation.id)
    end

    private_class_method def self.removed_wrapper?(operation)
      status = Status.unscoped.find_by(id: operation.old_status_id)
      status.nil? || status.deleted_at.present?
    end

    private_class_method def self.active_wrapper?(operation)
      Status.where(account_id: operation.account_id, reblog_of_id: operation.reblog_of_id).exists?
    end
  end
end
