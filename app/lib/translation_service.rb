# frozen_string_literal: true

class TranslationService
  class Error < StandardError; end
  class NotConfiguredError < Error; end
  class TooManyRequestsError < Error; end
  class QuotaExceededError < Error; end
  class UnexpectedResponseError < Error; end

  def self.configured
    if ENV['DEEPL_API_KEY'].present?
      TranslationService::DeepL.new(ENV.fetch('DEEPL_PLAN', 'free'), ENV['DEEPL_API_KEY'])
    elsif ENV['LIBRE_TRANSLATE_ENDPOINT'].present?
      TranslationService::LibreTranslate.new(ENV['LIBRE_TRANSLATE_ENDPOINT'], ENV['LIBRE_TRANSLATE_API_KEY'])
    else
      raise NotConfiguredError
    end
  end

  def self.configured?
    ENV['DEEPL_API_KEY'].present? || ENV['LIBRE_TRANSLATE_ENDPOINT'].present?
  end

  # Uses the same provider selection as `.configured`. DeepL stays false.
  def self.private_content_allowed?
    configured.private_content_allowed?
  rescue NotConfiguredError
    false
  end

  def self.timeout
    raw = ENV['TRANSLATION_TIMEOUT']
    return if raw.blank?

    seconds = Integer(raw, exception: false)
    seconds if seconds&.positive?
  end

  def self.timeout_options
    seconds = timeout
    return if seconds.nil?

    { read_timeout: seconds, read_deadline: seconds }
  end

  def languages
    {}
  end

  def translate(_text, _source_language, _target_language)
    raise NotImplementedError
  end

  def private_content_allowed?
    false
  end
end
