# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Test seam for real database races. Production callers leave it unused.
    # Names: :after_policy_lock, :before_status_create, :before_mapping_insert.
    module Checkpoints
      EVENT = 'external_bridge.link_sharing'

      def self.fire(name, extra = nil)
        ActiveSupport::Notifications.instrument(EVENT, name: name, extra: extra)
      end
    end
  end
end
