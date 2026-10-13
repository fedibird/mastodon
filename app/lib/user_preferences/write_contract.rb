# frozen_string_literal: true

class UserPreferences::WriteContract
  include LanguagesHelper

  KEYS = %w(
    default_privacy
    default_sensitive
    default_language
    show_translation_bar
    translation_preferred_mode
    new_features_policy
    content_font_size
    info_font_size
    reduce_motion
  ).freeze

  POLICIES = %w(conservative default tester).freeze
  FONT_RANGE = (10..20)

  Request = Struct.new(:updates, :resets, keyword_init: true) do
    def keys
      updates.keys + resets
    end

    def empty?
      updates.empty? && resets.empty?
    end
  end

  def validate!(updates:, resets:)
    errors = []
    copied_updates = copy_updates(updates, errors)
    copied_resets = copy_resets(resets, errors)
    copied_updates.each_key do |key|
      errors << error(key, 'duplicate_operation') if copied_resets.include?(key)
    end
    raise UserPreferences::InvalidInput, errors if errors.any?

    Request.new(updates: copied_updates, resets: copied_resets)
  end

  private

  def copy_updates(updates, errors)
    unless updates.is_a?(Hash)
      errors << error(nil, 'invalid_updates')
      return {}
    end

    copied = {}
    updates.each do |key, value|
      name = string_key(key, errors)
      next if name.nil?
      next unless known_key?(name, errors)
      next unless acceptable_value?(name, value, errors)

      copied[name] = value
    end
    copied
  end

  def copy_resets(resets, errors)
    unless resets.is_a?(Array)
      errors << error(nil, 'invalid_resets')
      return []
    end

    copied = []
    resets.each do |key|
      name = string_key(key, errors)
      next if name.nil?
      next unless known_key?(name, errors)
      next if copied.include?(name)

      copied << name
    end
    copied
  end

  def string_key(key, errors)
    return key if key.is_a?(String)

    errors << error(nil, 'invalid_key')
    nil
  end

  def known_key?(key, errors)
    return true if KEYS.include?(key)

    errors << error(key, 'unknown_key')
    false
  end

  def acceptable_value?(key, value, errors)
    if value.nil?
      errors << error(key, 'null_value')
      return false
    end

    return true if allowed?(key, value)

    errors << error(key, type_matches?(key, value) ? 'invalid_value' : 'invalid_type')
    false
  end

  def allowed?(key, value)
    case key
    when 'default_privacy'
      value.is_a?(String) && Status.selectable_visibilities.include?(value)
    when 'default_sensitive', 'reduce_motion'
      value == true || value == false
    when 'default_language'
      value.is_a?(String) && valid_locale?(value)
    when 'show_translation_bar'
      value.is_a?(String) && TranslationPreferences::VISIBILITIES.include?(value)
    when 'translation_preferred_mode'
      value.is_a?(String) && TranslationPreferences::PREFERRED_MODES.include?(value)
    when 'new_features_policy'
      value.is_a?(String) && POLICIES.include?(value)
    when 'content_font_size', 'info_font_size'
      value.is_a?(Integer) && FONT_RANGE.cover?(value)
    else
      false
    end
  end

  def type_matches?(key, value)
    case key
    when 'default_sensitive', 'reduce_motion'
      value == true || value == false
    when 'content_font_size', 'info_font_size'
      value.is_a?(Integer)
    else
      value.is_a?(String)
    end
  end

  def error(key, code)
    { 'key' => key, 'code' => code }
  end
end
