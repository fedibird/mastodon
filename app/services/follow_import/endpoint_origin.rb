# frozen_string_literal: true

# Origin of an actual HTTP request (scheme + host + non-default port).
# Never returns a path, query, or fragment — inbox URLs must not be stored.
module FollowImport
  module EndpointOrigin
    module_function

    def from_url(url)
      return if url.blank?

      Addressable::URI.parse(url).normalized_site.presence
    rescue StandardError
      nil
    end
  end
end
