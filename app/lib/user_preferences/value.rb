# frozen_string_literal: true

# Read-only view of one preference.
#
# state is one of :absent, :nil, :present, or :derived.
# :absent means no settings row. :nil means a row whose YAML value is nil.
# :present means a row with a value, including false and "".
# configured is nil for :absent and :nil, and the stored value otherwise.
# effective follows the current User getter. public_value is the API form.
class UserPreferences::Value
  attr_reader :key, :state, :configured, :effective, :public_value

  def initialize(key:, state:, configured:, effective:, public_value:)
    @key = key
    @state = state
    @configured = configured
    @effective = effective
    @public_value = public_value
    freeze
  end

  def stored?
    state == :present || state == :nil
  end

  def absent?
    state == :absent
  end

  def derived?
    state == :derived
  end
end
