# frozen_string_literal: true

# Turns a JSON reset list of public keys into Writer internal keys.
# It uses the same allowlist as PatchDocument and does not touch storage.
class UserPreferences::ResetDocument
  def self.parse(payload)
    new(payload).keys
  end

  def initialize(payload)
    @payload = payload
  end

  def keys
    errors = []
    values = reset_values(errors)
    mapped = map_values(values, errors)
    raise UserPreferences::InvalidInput, errors if errors.any?

    mapped
  end

  private

  def reset_values(errors)
    unless @payload.is_a?(Hash)
      errors << error(nil, 'invalid_body')
      return []
    end

    @payload.each_key do |key|
      name = key.is_a?(String) ? key : nil
      errors << error(name, 'unknown_key') unless name == 'reset'
    end

    unless @payload.key?('reset')
      errors << error('reset', 'blank')
      return []
    end

    reset = @payload['reset']
    return reset if reset.is_a?(Array)

    errors << error('reset', 'invalid_type')
    []
  end

  def map_values(values, errors)
    mapped = []
    values.each do |item|
      unless item.is_a?(String)
        errors << error(nil, 'invalid_key')
        next
      end

      internal = UserPreferences::PatchDocument::PUBLIC_KEYS[item]
      if internal.nil?
        errors << error(item, 'unknown_key')
        next
      end

      mapped << internal unless mapped.include?(internal)
    end
    mapped
  end

  def error(key, code)
    { 'key' => key, 'code' => code }
  end
end
