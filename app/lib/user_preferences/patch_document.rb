# frozen_string_literal: true

# Turns a JSON object of public preference keys into Writer internal keys.
# It does not strip an arbitrary "user." prefix and it does not read the database.
class UserPreferences::PatchDocument
  PUBLIC_KEYS = UserPreferences::WriteContract::KEYS.to_h { |key| ["user.#{key}", key] }.freeze

  def self.parse(payload)
    new(payload).updates
  end

  def initialize(payload)
    @payload = payload
  end

  def updates
    errors = []
    preferences = preferences_object(errors)
    mapped = map_preferences(preferences, errors)
    raise UserPreferences::InvalidInput, errors if errors.any?

    mapped
  end

  private

  def preferences_object(errors)
    unless @payload.is_a?(Hash)
      errors << error(nil, 'invalid_body')
      return {}
    end

    @payload.each_key do |key|
      name = key.is_a?(String) ? key : nil
      errors << error(name, 'unknown_key') unless name == 'preferences'
    end

    unless @payload.key?('preferences')
      errors << error('preferences', 'blank')
      return {}
    end

    preferences = @payload['preferences']
    return preferences if preferences.is_a?(Hash)

    errors << error('preferences', 'invalid_type')
    {}
  end

  def map_preferences(preferences, errors)
    mapped = {}
    preferences.each do |key, value|
      unless key.is_a?(String)
        errors << error(nil, 'invalid_key')
        next
      end

      internal = PUBLIC_KEYS[key]
      if internal.nil?
        errors << error(key, 'unknown_key')
        next
      end

      mapped[internal] = value
    end
    mapped
  end

  def error(key, code)
    { 'key' => key, 'code' => code }
  end
end
