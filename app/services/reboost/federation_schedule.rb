# frozen_string_literal: true

module Reboost
  # Records that a federation job was queued, and queues home distribution and
  # federation again when a later pass finds a federating operation that never
  # stored those timestamps.
  module FederationSchedule
    def enqueue_federation!(operation)
      Reboost::DeliveryResume.enqueue_federation!(operation)
    end

    def ensure_federating!(status)
      return if status.nil?

      operation = ReboostOperation.where(account_id: account.id, new_status_id: status.id, state: 'federating').order(id: :desc).first
      Reboost::DeliveryResume.resume!(operation) if operation
    end
  end
end
