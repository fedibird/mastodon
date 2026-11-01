# frozen_string_literal: true

# Host of an already stored actor URI. Parsing does not resolve DNS and
# does not follow redirects.
class GroupProtocol::ActorHost
  def self.for_account(account)
    raw = account.uri.to_s
    return if raw.empty?

    parsed = Addressable::URI.parse(raw)
    return unless %w(http https).include?(parsed.scheme&.downcase)

    parsed.normalized_host&.downcase
  rescue Addressable::URI::InvalidURIError, ArgumentError
    nil
  end
end
