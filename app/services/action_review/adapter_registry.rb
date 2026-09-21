# frozen_string_literal: true

# Operations that can accept a moderator approve/reject.
# Unregistered operations fail closed; they are not silently skipped.
module ActionReview
  class AdapterRegistry
    class UnknownAdapter < StandardError; end

    ADAPTERS = {
      'follow_import' => ActionReview::Adapters::FollowImport,
    }.freeze

    def self.registered?(operation_type)
      ADAPTERS.key?(operation_type.to_s)
    end

    def self.fetch!(operation_type)
      adapter = ADAPTERS[operation_type.to_s]
      raise UnknownAdapter, "no action review decision adapter for #{operation_type.inspect}" if adapter.nil?

      adapter
    end
  end
end
