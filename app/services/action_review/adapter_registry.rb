# frozen_string_literal: true

# Operations that can accept a moderator approve/reject.
# Unregistered operations fail closed; they are not silently skipped.
module ActionReview
  class AdapterRegistry
    class UnknownAdapter < StandardError; end

    ADAPTERS = {
      'follow_import' => ActionReview::Adapters::FollowImport,
      'invite_creation' => ActionReview::Adapters::InviteCreation,
      'account_migration' => ActionReview::Adapters::AccountMigration,
    }.freeze

    def self.registered?(operation_type)
      ADAPTERS.key?(operation_type.to_s)
    end

    # Read-only. Unknown operations, missing rows, and malformed
    # snapshots are not actionable and are not mutated.
    def self.actionable?(request)
      return false if request.nil?

      adapter = ADAPTERS[request.operation_type.to_s]
      return false if adapter.nil? || !adapter.respond_to?(:actionable?)

      adapter.actionable?(request)
    rescue StandardError
      false
    end

    def self.fetch!(operation_type)
      adapter = ADAPTERS[operation_type.to_s]
      raise UnknownAdapter, "no action review decision adapter for #{operation_type.inspect}" if adapter.nil?

      adapter
    end
  end
end
