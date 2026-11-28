# frozen_string_literal: true

# Stored nil (or a missing row) follows new_features_policy and is not written
# back. An explicit true or false wins over a later policy change.
module ReboostPreferences
  CHOICES = %w(auto on off).freeze

  module_function

  def enabled?(stored, policy)
    case normalize_choice(stored)
    when true
      true
    when false
      false
    else
      policy.to_s != 'conservative'
    end
  end

  # true, false, or nil. :invalid when the value cannot be stored.
  def normalize_choice(value)
    case value
    when true, 'on', 'true'
      true
    when false, 'off', 'false'
      false
    when nil, '', 'auto'
      nil
    else
      :invalid
    end
  end

  def choice(stored)
    case normalize_choice(stored)
    when true
      'on'
    when false
      'off'
    when nil
      'auto'
    else
      'auto'
    end
  end
end
