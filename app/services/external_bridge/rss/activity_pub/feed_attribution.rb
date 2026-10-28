# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # A weak guess that this RSS document might come from an ActivityPub
      # implementation. The result is "likely" or "unknown", never a
      # confirmed origin. NodeInfo and an item that returned ActivityStreams
      # are not inputs.
      class FeedAttribution
        def self.evaluate(feed:, feed_url:)
          return ExternalSource::FEED_ATTRIBUTION_UNKNOWN unless feed.activitypub_generator_hint

          host = http_host(feed_url)
          return ExternalSource::FEED_ATTRIBUTION_UNKNOWN if host.blank?
          return ExternalSource::FEED_ATTRIBUTION_LIKELY if feed.items.any? { |item| entry_on_host?(item, host) }

          ExternalSource::FEED_ATTRIBUTION_UNKNOWN
        end

        def self.entry_on_host?(item, host)
          [item.activitypub_url, item.key, item.canonical_url, item.activitypub_sample_url].any? do |value|
            http_host(value) == host
          end
        end
        private_class_method :entry_on_host?

        def self.http_host(value)
          uri = Addressable::URI.parse(value.to_s.strip)
          return nil unless uri&.scheme.to_s.match?(/\Ahttps?\z/i)

          uri.normalized_host.presence
        rescue Addressable::URI::InvalidURIError
          nil
        end
        private_class_method :http_host
      end
    end
  end
end
