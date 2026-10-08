# frozen_string_literal: true

class PostingContext::RevalidationEligibility
  class << self
    include DomainControlHelper

    # Remote ActivityPub groups with a stored actor URI. Discovery support is
    # intentionally not required: permission evidence is independent of the
    # posting adapter. Local Fedibird groups are not part of this refresh.
    def eligible?(account)
      return false if account.nil? || account.local? || !account.group?
      return false unless account.activitypub?
      return false if account.suspended?
      return false unless usable_actor_uri?(account.uri)
      return false if domain_not_allowed?(account.domain) || domain_not_allowed?(account.uri)

      true
    end

    def usable_actor_uri?(uri)
      parsed = Addressable::URI.parse(uri)
      parsed.present? && %w(http https).include?(parsed.scheme) && parsed.host.present?
    rescue Addressable::URI::InvalidURIError
      false
    end
  end
end
