# frozen_string_literal: true

# Reads site-wide Action Review intervention modes from Setting.
#
# Defaults in config/settings.yml are all `off`, so a stock install never
# requires review. This reader does not silently accept an unknown
# operation (raises). Malformed configuration is conservative:
#
# - missing / blank per-operation key -> `off` (unconfigured)
# - unrecognized configured value, or a non-hash setting blob -> `always`
#   so a typo cannot silently disable intended intervention
#
# `always` is a review-required policy, not an automatic reject.
module ActionReview
  class PolicySettings
    MALFORMED_FALLBACK_MODE = 'always'

    def self.mode_for(operation_type)
      new.mode_for(operation_type)
    end

    def mode_for(operation_type)
      ActionReview::OperationRegistry.fetch!(operation_type)
      hash = policies_hash
      return MALFORMED_FALLBACK_MODE if hash.nil?

      normalize_configured_value(hash[operation_type.to_s])
    end

    def self.supported_modes_for(operation_type)
      ActionReview::OperationRegistry.supported_policy_modes(operation_type)
    end

    def self.normalize_mode(value)
      new.normalize_configured_value(value)
    end

    def normalize_configured_value(value)
      return 'off' if value.nil? || value == false
      return MALFORMED_FALLBACK_MODE unless value.is_a?(String) || value.is_a?(Symbol)

      text = value.to_s.strip.downcase
      return 'off' if text.empty?
      return text if ActionReview::OperationRegistry::POLICY_MODES.include?(text)

      MALFORMED_FALLBACK_MODE
    end

    private

    def policies_hash
      raw = Setting['action_review_policies']
      return unless raw.is_a?(Hash)

      raw.with_indifferent_access
    rescue StandardError
      nil
    end
  end
end
