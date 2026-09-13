# frozen_string_literal: true

# Generic, failure-tolerant dispatcher for optional delivery tracking on
# ActivityPub::DeliveryWorker. A caller may attach opaque `delivery_tracking`
# metadata of the form { 'type' => '<registered type>', 'id' => <id> } to the
# worker options; on HTTP delivery success (or once Sidekiq retries are
# exhausted) the worker routes that metadata here, and it is dispatched to the
# handler registered for the type.
#
# This keeps DeliveryWorker free of any feature-specific logic. Handlers must be
# side-effect-safe to call and are wrapped so a tracking failure can never break
# or retry a delivery.
module ActivityPub
  module DeliveryTracking
    # type => handler responding to .delivered(id) and .failed(id).
    HANDLERS = {
      'follow_import_target' => 'FollowImport::TargetDeliveryTracker',
    }.freeze

    module_function

    def delivered(tracking)
      dispatch(tracking, :delivered)
    end

    def failed(tracking)
      dispatch(tracking, :failed)
    end

    def dispatch(tracking, event)
      handler, id = resolve(tracking)
      return if handler.nil? || id.nil?

      handler.public_send(event, id)
    rescue StandardError => e
      Rails.logger.warn("[ActivityPub::DeliveryTracking] #{event} dispatch failed: #{e.class}: #{e.message}")
      nil
    end

    def resolve(tracking)
      return [nil, nil] unless tracking.is_a?(Hash)

      type = tracking['type'] || tracking[:type]
      id   = tracking['id'] || tracking[:id]
      handler_name = HANDLERS[type]
      return [nil, nil] if handler_name.nil?

      [handler_name.constantize, id]
    end
  end
end
