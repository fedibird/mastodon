# frozen_string_literal: true

module Reboost
  # Undo leaves this process only after the old wrapper is gone or discarded.
  # A terminal row keeps that decision: a payload with no undo_enqueued_at still
  # needs delivery, and the scheduler can enqueue that delivery again.
  module UndoDelivery
    module_function

    def settle!(operation)
      return if operation.nil?

      operation.reload
      return if operation.undo_enqueued_at.present? || operation.undo_payload.blank?

      if due?(operation)
        enqueue!(operation)
      else
        release!(operation)
      end
    end

    # A boost that is still present keeps its remote copy. A removed or
    # discarded wrapper, or a saved Undo with no wrapper left, is delivered.
    def due?(operation)
      return false if operation.nil? || operation.undo_payload.blank? || operation.undo_enqueued_at.present?
      return false if active_wrapper?(operation)

      operation.old_status_id.blank? || removed_wrapper?(operation)
    end

    def enqueue!(operation)
      return if operation.nil? || operation.undo_payload.blank? || operation.undo_enqueued_at.present?

      Reboost::FederationWorker.perform_async(operation.id)
    end

    private_class_method def self.release!(operation)
      operation.update!(undo_payload: nil, undo_inboxes: [])
    end

    private_class_method def self.removed_wrapper?(operation)
      return false if operation.old_status_id.blank?

      status = Status.unscoped.find_by(id: operation.old_status_id)
      status.nil? || status.deleted_at.present?
    end

    private_class_method def self.active_wrapper?(operation)
      Status.where(account_id: operation.account_id, reblog_of_id: operation.reblog_of_id).exists?
    end
  end
end
