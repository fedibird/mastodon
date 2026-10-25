# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Icon
      # The only icon address that leaves the server. It points at Fedibird,
      # never at the feed's own image, and it carries the stored file's SHA-256
      # so a replaced icon gets a new URL and a stale one stops resolving. The
      # fingerprint is not a secret; it is the cache key.
      module Delivery
        module_function

        def url(source)
          return nil unless stored?(source)

          Rails.application.routes.url_helpers.external_source_icon_url(
            source.id,
            source.icon_fingerprint,
            **ActionMailer::Base.default_url_options
          )
        end

        def stored?(source)
          source.present? && source.icon_fingerprint.present? && source.icon_file_name.present?
        end
      end
    end
  end
end
