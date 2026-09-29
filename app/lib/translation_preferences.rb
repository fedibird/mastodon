# frozen_string_literal: true

module TranslationPreferences
  VISIBILITIES = %w(always target never).freeze
  PREFERRED_MODES = %w(translated bilingual both).freeze

  module_function

  # A stored true/false is an explicit legacy choice. nil and unknown values
  # are not choices: they follow new_features_policy and are not written back.
  def normalize_visibility(stored, policy)
    case stored
    when true
      'always'
    when false
      'never'
    else
      value = stored.to_s
      return value if VISIBILITIES.include?(value)

      default_visibility(policy)
    end
  end

  def default_visibility(policy)
    case policy.to_s
    when 'conservative'
      'never'
    when 'tester'
      'always'
    else
      'target'
    end
  end

  def normalize_preferred_mode(value)
    mode = value.to_s
    PREFERRED_MODES.include?(mode) ? mode : 'translated'
  end
end
