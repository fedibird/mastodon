# frozen_string_literal: true

class UserPostingContext
  # Storage contract for schema_version 1.
  #
  # A missing key is inheritance. A present value is an explicit choice.
  # Explicit clears are objects, not JSON null:
  #   language: { "mode": "auto" }
  #   spoiler:  { "enabled": false }
  # Language explicit: { "mode": "explicit", "code": "ja" }
  # Spoiler explicit:  { "enabled": true, "text": "..." }
  # visibility is a Status visibility name. sensitive is true or false.
  class Defaults
    KEYS = %w(visibility language sensitive spoiler).freeze
    SPOILER_TEXT_LIMIT = 500

    def self.form_fields(defaults)
      data = stringify(defaults)
      visibility = data['visibility']
      language = data['language']
      sensitive = data['sensitive']
      spoiler = data['spoiler']

      {
        visibility_choice: visibility.nil? ? 'inherit' : 'explicit',
        visibility_value: visibility.to_s,
        language_choice: language_choice(language),
        language_code: language.is_a?(Hash) ? language['code'].to_s : '',
        sensitive_choice: sensitive.nil? ? 'inherit' : 'explicit',
        sensitive_value: sensitive.nil? ? '' : sensitive.to_s,
        spoiler_choice: spoiler_choice(spoiler),
        spoiler_text: spoiler.is_a?(Hash) ? spoiler['text'].to_s : '',
      }
    end

    def self.write(record)
      original = stringify(record.defaults)
      payload = {}
      write_visibility(record, original, payload)
      write_language(record, original, payload)
      write_sensitive(record, original, payload)
      write_spoiler(record, original, payload)
      record.defaults = payload
    end

    def self.validate_stored(record)
      data = record.defaults
      return record.errors.add(:base, I18n.t('user_posting_contexts.errors.defaults')) unless data.is_a?(Hash)

      parsed = data.deep_stringify_keys
      return record.errors.add(:base, I18n.t('user_posting_contexts.errors.defaults')) if (parsed.keys - KEYS).any?

      validate_visibility(record, parsed)
      validate_language(record, parsed)
      validate_sensitive(record, parsed)
      validate_spoiler(record, parsed)
    end

    def self.write_visibility(record, original, payload)
      unless record.submitted?('visibility_choice')
        payload['visibility'] = original['visibility'] if original.key?('visibility')
        return
      end

      case record.visibility_choice
      when 'inherit'
        nil
      when 'explicit'
        payload['visibility'] = record.visibility_value.to_s
      else
        record.errors.add(:base, I18n.t('user_posting_contexts.errors.visibility_choice'))
      end
    end

    def self.write_language(record, original, payload)
      unless record.submitted?('language_choice')
        payload['language'] = original['language'] if original.key?('language')
        return
      end

      case record.language_choice
      when 'inherit'
        nil
      when 'auto'
        payload['language'] = { 'mode' => 'auto' }
      when 'explicit'
        payload['language'] = { 'mode' => 'explicit', 'code' => record.language_code.to_s }
      else
        record.errors.add(:base, I18n.t('user_posting_contexts.errors.language_choice'))
      end
    end

    def self.write_sensitive(record, original, payload)
      unless record.submitted?('sensitive_choice')
        payload['sensitive'] = original['sensitive'] if original.key?('sensitive')
        return
      end

      case record.sensitive_choice
      when 'inherit'
        nil
      when 'explicit'
        if record.sensitive_value == 'true'
          payload['sensitive'] = true
        elsif record.sensitive_value == 'false'
          payload['sensitive'] = false
        else
          record.errors.add(:base, I18n.t('user_posting_contexts.errors.sensitive_value'))
        end
      else
        record.errors.add(:base, I18n.t('user_posting_contexts.errors.sensitive'))
      end
    end

    def self.write_spoiler(record, original, payload)
      unless record.submitted?('spoiler_choice')
        payload['spoiler'] = original['spoiler'] if original.key?('spoiler')
        return
      end

      case record.spoiler_choice
      when 'inherit'
        nil
      when 'disabled'
        payload['spoiler'] = { 'enabled' => false }
      when 'enabled'
        payload['spoiler'] = { 'enabled' => true, 'text' => record.spoiler_text.to_s }
      else
        record.errors.add(:base, I18n.t('user_posting_contexts.errors.spoiler_choice'))
      end
    end

    def self.validate_visibility(record, data)
      return unless data.key?('visibility')

      value = data['visibility']
      return if value.is_a?(String) && Status.visibilities.key?(value)

      record.errors.add(:base, I18n.t('user_posting_contexts.errors.visibility'))
    end

    def self.validate_language(record, data)
      return unless data.key?('language')

      language = data['language']
      return record.errors.add(:base, I18n.t('user_posting_contexts.errors.language')) unless language.is_a?(Hash)

      parsed = language.deep_stringify_keys
      if parsed == { 'mode' => 'auto' }
        return
      end

      code = parsed['code']
      return if parsed.keys.sort == %w(code mode) && parsed['mode'] == 'explicit' && known_language?(code)

      record.errors.add(:base, I18n.t('user_posting_contexts.errors.language'))
    end

    def self.validate_sensitive(record, data)
      return unless data.key?('sensitive')
      return if data['sensitive'] == true || data['sensitive'] == false

      record.errors.add(:base, I18n.t('user_posting_contexts.errors.sensitive_value'))
    end

    def self.validate_spoiler(record, data)
      return unless data.key?('spoiler')

      spoiler = data['spoiler']
      return record.errors.add(:base, I18n.t('user_posting_contexts.errors.spoiler_shape')) unless spoiler.is_a?(Hash)

      parsed = spoiler.deep_stringify_keys
      if parsed == { 'enabled' => false }
        return
      end

      text = parsed['text']
      valid = parsed.keys.sort == %w(enabled text) && parsed['enabled'] == true && text.is_a?(String) && text.length <= SPOILER_TEXT_LIMIT
      valid &&= text.match?(/\A[^\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]*\z/)
      return if valid

      record.errors.add(:base, I18n.t('user_posting_contexts.errors.spoiler_text'))
    end

    def self.language_choice(language)
      return 'inherit' unless language.is_a?(Hash)
      return 'auto' if language['mode'] == 'auto'
      return 'explicit' if language['mode'] == 'explicit'

      'inherit'
    end

    def self.spoiler_choice(spoiler)
      return 'inherit' unless spoiler.is_a?(Hash)
      return 'disabled' if spoiler['enabled'] == false
      return 'enabled' if spoiler['enabled'] == true

      'inherit'
    end

    def self.known_language?(code)
      code.is_a?(String) && LanguagesHelper::SUPPORTED_LOCALES.key?(code.to_sym)
    end

    def self.stringify(value)
      return {} unless value.is_a?(Hash)

      value.deep_stringify_keys
    end

    private_class_method :write_visibility, :write_language, :write_sensitive, :write_spoiler,
                         :validate_visibility, :validate_language, :validate_sensitive, :validate_spoiler,
                         :language_choice, :spoiler_choice, :known_language?, :stringify
  end
end
