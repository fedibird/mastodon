# frozen_string_literal: true

class TranslationService
  class Error < StandardError; end
  class NotConfiguredError < Error; end
  class TooManyRequestsError < Error; end
  class QuotaExceededError < Error; end
  class UnexpectedResponseError < Error; end

  # More than one usable personal DeepL credential. Fail closed: do not pick
  # a row and do not fall back to the instance provider.
  class AmbiguousPersonalProvider < Error; end

  # Instance-wide provider. `.configured` and `.configured?` stay instance-only
  # so Mastodon-compatible instance APIs do not change meaning.
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

  # Viewer-specific provider. Pass the user explicitly; there is no thread-local
  # current user. `nil` keeps the instance provider.
  #
  # Precedence: one usable personal DeepL credential, then instance DeepL, then
  # instance LibreTranslate. A credential that is already revoked or expired is
  # absent, so instance fallback is allowed. After a personal provider is
  # returned, later failures stay on that provider.
  def self.for_user(user)
    return configured if user.nil?

    personal = TranslationService::PersonalDeepL.resolve(user)
    return personal if personal

    configured
  end

  # True when `for_user` can select a provider. Two usable personal DeepL
  # credentials are false so the request fails closed.
  def self.configured_for?(user)
    return configured? if user.nil?

    case TranslationService::PersonalDeepL.availability(user)
    when :one
      true
    when :many
      false
    else
      configured?
    end
  end

  # Uses the same provider selection as `.configured`. DeepL stays false.
  def self.private_content_allowed?
    configured.private_content_allowed?
  rescue NotConfiguredError
    false
  end

  # Effective provider for this viewer, including a personal DeepL credential.
  # Anonymous callers keep the instance value via `user: nil`.
  def self.private_content_allowed_for(user)
    for_user(user).private_content_allowed?
  rescue NotConfiguredError, AmbiguousPersonalProvider
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
