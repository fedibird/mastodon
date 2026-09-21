# frozen_string_literal: true

# Catalog of operations that may participate in Action Review.
#
# Capability metadata only. Do not add execution / release adapters here.
module ActionReview
  class OperationRegistry
    class UnknownOperation < ArgumentError; end

    OPERATIONS = {
      'follow_import' => { automated_signal: true }.freeze,
      'account_migration' => { automated_signal: false }.freeze,
      'invite_creation' => { automated_signal: false }.freeze,
      'status_import' => { automated_signal: false }.freeze,
    }.freeze

    POLICY_MODES = %w(off high medium low always).freeze
    DETECTORLESS_POLICY_MODES = %w(off always).freeze
    SIGNAL_LEVELS = %w(none low medium high).freeze

    def self.keys
      OPERATIONS.keys
    end

    def self.registered?(operation_type)
      OPERATIONS.key?(operation_type.to_s)
    end

    def self.fetch!(operation_type)
      entry = OPERATIONS[operation_type.to_s]
      raise UnknownOperation, "unknown action review operation: #{operation_type.inspect}" if entry.nil?

      entry
    end

    def self.automated_signal?(operation_type)
      fetch!(operation_type).fetch(:automated_signal)
    end

    def self.supported_policy_modes(operation_type)
      if automated_signal?(operation_type)
        POLICY_MODES
      else
        DETECTORLESS_POLICY_MODES
      end
    end
  end
end
