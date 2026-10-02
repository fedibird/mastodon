# frozen_string_literal: true

# Resolves one redirect-host URL into a RedirectLink.
#
# An unchanged final URL is stored as an identity mapping
# (url == redirected_url). Formatter treats a missing RedirectLink on a
# redirect host as unresolved, so a successful check has to be persisted
# even when the URL should be shown as-is.
class ResolveRedirectLinkService < BaseService
  class ResolutionError < StandardError
    attr_reader :url

    def initialize(url, message = nil)
      @url = url
      super(message || "Redirect resolution failed for #{url}")
    end
  end

  class TemporaryFailure < ResolutionError; end
  class PermanentFailure < ResolutionError; end

  # Same-host language prefix that the historical resolver ignored.
  LANGUAGE_ONLY_PATH = %r{\A(?:|/[A-Za-z]{2,}(?:[_-][A-Za-z]{2,})?)\z}
  TEMPORARY_STATUS_CODES = [408, 425, 429, 500, 502, 503, 504].freeze

  # @return [RedirectLink, nil] nil when the URL is not a redirect target
  def call(url)
    normalized = normalize_url(url)
    return if normalized.nil? || !FetchLinkCardService.redirect_target_host?(normalized.host)

    RedirectLink.find_by(url: normalized.to_s) || resolve!(normalized)
  end

  private

  def resolve!(uri)
    code, final_uri = fetch(uri.to_s)
    return persist_identity!(uri) if success?(code) && unchanged_or_language_only?(uri, final_uri)
    return persist_confirmed_redirect!(uri, final_uri) if success?(code) && final_uri.present?

    raise_for_status!(uri.to_s, success?(code) ? nil : code)
  end

  def unchanged_or_language_only?(original, final_uri)
    unchanged?(original, final_uri) || language_only_redirect?(original, final_uri)
  end

  def persist_identity!(uri)
    persist!(uri.to_s, uri.to_s)
  end

  def persist_confirmed_redirect!(original, final_uri)
    code, = fetch(final_uri.to_s)
    raise_for_status!(original.to_s, code) unless success?(code)

    persist!(original.to_s, final_uri.to_s)
  rescue ResolutionError => e
    raise e.class.new(original.to_s, e.message)
  end

  def persist!(url, redirected_url)
    RedirectLink.create!(url: url, redirected_url: redirected_url)
  rescue ActiveRecord::RecordNotUnique
    RedirectLink.find_by!(url: url)
  rescue ActiveRecord::RecordInvalid => e
    raise PermanentFailure.new(url, e.message)
  end

  def fetch(url)
    code = nil
    final_uri = nil

    Request.new(:get, url).add_headers('User-Agent' => "#{Mastodon::Version.user_agent} Bot").perform do |response|
      code = response.code.to_i
      final_uri = Addressable::URI.parse(response.uri.to_s).normalize
    end

    [code, final_uri]
  rescue HTTP::Error, OpenSSL::SSL::SSLError => e
    raise TemporaryFailure.new(url, "#{e.class}: #{e.message}")
  rescue Addressable::URI::InvalidURIError, Mastodon::HostValidationError, ArgumentError => e
    raise PermanentFailure.new(url, "#{e.class}: #{e.message}")
  end

  def success?(code)
    code.to_i == 200
  end

  def unchanged?(original, final_uri)
    final_uri.present? && original.to_s == final_uri.to_s
  end

  def language_only_redirect?(original, final_uri)
    return false if final_uri.blank? || unchanged?(original, final_uri)
    return false if original.normalized_host.blank? || final_uri.normalized_host.blank?

    original.normalized_host.casecmp(final_uri.normalized_host)&.zero? &&
      final_uri.path.to_s.match?(LANGUAGE_ONLY_PATH)
  end

  def raise_for_status!(url, code)
    if code.nil? || temporary_status?(code)
      raise TemporaryFailure.new(url, "temporary HTTP #{code} for #{url}")
    end

    raise PermanentFailure.new(url, "permanent HTTP #{code} for #{url}")
  end

  def temporary_status?(code)
    number = code.to_i
    TEMPORARY_STATUS_CODES.include?(number) || (300..399).cover?(number)
  end

  def normalize_url(url)
    uri = Addressable::URI.parse(url.to_s)&.normalize
    return if uri.blank? || uri.host.blank? || !%w(http https).include?(uri.scheme)
    return if uri.to_s.bytesize > FetchLinkCardService::BYTESIZE_LIMIT

    uri
  rescue Addressable::URI::InvalidURIError, ArgumentError
    nil
  end
end
