# frozen_string_literal: true

# Resolves a locally known remote resource without searching unindexed status URLs.
#
# The ActivityPub id (stored as uri) is the resource identity. A remote
# object's human-facing url is only a claimed representation, not an identity:
# aggregators can legitimately set it to an article on somebody else's site.
class ActivityPub::KnownResourceResolver
  MASTODON_STATUS_URL_RE = %r{\A/@(?<username>#{Account::USERNAME_RE})/(?:statuses/)?(?<status_id>[0-9a-zA-Z]+)\z}.freeze

  def initialize(url)
    @url = url
  end

  def status
    return if @url.blank?

    # The unique uri index always takes precedence over any URL alias.
    status = Status.find_by(uri: @url)
    return status unless status.nil?

    uri = mastodon_status_uri
    return if uri.nil?

    # The uri index finds at most one row; url is only checked on that row.
    Status.find_by(uri: uri, url: @url)
  end

  def account
    return if @url.blank?

    account = Account.find_by(uri: @url)
    return account unless account.nil?

    return if web_url(@url).nil?

    # accounts.url has an index, unlike the status URL index we intend to
    # retire. Refuse ambiguous aliases and third-party URLs.
    candidates = Account.where(url: @url).limit(2).to_a
    return unless candidates.one?

    account = candidates.first
    account if same_origin?(@url, account.uri)
  end

  private

  def mastodon_status_uri
    parsed = web_url(@url)
    return if parsed.nil? || parsed.query.present? || parsed.fragment.present?

    match = MASTODON_STATUS_URL_RE.match(parsed.path)
    return if match.nil?

    parsed.path = "/users/#{match[:username]}/statuses/#{match[:status_id]}"
    parsed.to_s
  end

  def same_origin?(first_url, second_url)
    first  = web_url(first_url)
    second = web_url(second_url)
    return false if first.nil? || second.nil?

    first.scheme.casecmp(second.scheme).zero? &&
      first.normalized_host == second.normalized_host &&
      effective_port(first) == effective_port(second)
  end

  def effective_port(uri)
    uri.port || (uri.scheme.casecmp('https').zero? ? 443 : 80)
  end

  def web_url(url)
    parsed = Addressable::URI.parse(url)
    return unless %w(http https).include?(parsed.scheme&.downcase) && parsed.host.present? && parsed.userinfo.blank?

    parsed
  rescue ArgumentError, Addressable::URI::InvalidURIError, IDN::Idna::IdnaError
    nil
  end
end
