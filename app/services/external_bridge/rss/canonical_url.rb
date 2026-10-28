# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Public feed and item URLs. Query strings are fail-closed: the only
    # stored form is a known-safe format parameter. Unknown names, credential
    # aliases, and percent-encoding that does not resolve are rejected before
    # HTTP and before a shared row is written.
    class CanonicalURL
      SAFE_QUERY_NAMES = %w(format).freeze
      SAFE_FORMAT_VALUES = %w(rss atom xml feed).freeze
      MAX_DECODE = 8

      # Feed icons and site pages are public assets, and CDNs routinely append a
      # cache-busting version. Only these names are kept, only as a short
      # token-free value, and never more than a few pairs. Any other name
      # (token, key, sig, auth, expires, ...) still fails closed.
      ASSET_QUERY_NAMES = %w(v ver version rev r t ts w h width height size s format cb max-w max-h fit auto ixlib).freeze
      ASSET_QUERY_VALUE = /\A[A-Za-z0-9._-]{1,32}\z/.freeze
      ASSET_QUERY_PAIRS = 6

      ITEM_QUERY = %w(id v video_id clip clip_id viewkey).freeze
      ITEM_VALUE = /\A[A-Za-z0-9_-]{1,80}\z/.freeze

      def self.normalize!(value, asset: false, item: false)
        new(value, asset: asset, item: item).normalize!
      end

      def self.safe_http?(value)
        normalize!(value)
        true
      rescue ExternalBridge::Error
        false
      end

      def initialize(value, asset: false, item: false)
        @value = value.to_s
        @asset = asset
        @item = item
      end

      def normalize!
        uri = parse!
        reject_userinfo!(uri)
        reject_query!(uri)
        reject_private_literal!(uri)
        uri.scheme = uri.scheme.downcase
        uri.host = uri.host.downcase
        uri.port = nil if uri.port == uri.default_port
        uri.fragment = nil
        uri.path = '' if uri.path == '/'
        key = uri.to_s
        raise Error, :unsupported_url if key.bytesize > Limits::MAX_KEY_BYTES

        key
      end

      private

      def parse!
        uri = Addressable::URI.parse(@value)
        raise Error, :unsupported_url if uri.nil?
        raise Error, :unsupported_url unless %w(http https).include?(uri.scheme&.downcase)
        raise Error, :unsupported_url if uri.host.blank?

        uri
      rescue Addressable::URI::InvalidURIError
        raise Error, :unsupported_url
      end

      def reject_userinfo!(uri)
        raise Error, :authenticated_source_rejected if uri.user.present? || uri.password.present?
      end

      def reject_private_literal!(uri)
        address = IPAddr.new(uri.host)
        raise Error, :private_address if PrivateAddressCheck.private_address?(address)
      rescue IPAddr::InvalidAddressError
        nil
      end

      def reject_query!(uri)
        return if uri.query.nil?
        raise Error, :authenticated_source_rejected if uri.query.blank? || malformed_percent?(uri.query)
        return reject_asset_query!(uri) if @asset
        return reject_item_query!(uri) if @item

        pairs = uri.query.split(/[&;]/)
        raise Error, :authenticated_source_rejected unless pairs.one?

        name, value = pairs.first.split('=', 2)
        raise Error, :authenticated_source_rejected if value.nil?

        decoded_name = fully_decode(name)
        decoded_value = fully_decode(value)
        raise Error, :authenticated_source_rejected if decoded_name.blank? || decoded_value.blank?
        raise Error, :authenticated_source_rejected unless SAFE_QUERY_NAMES.include?(decoded_name.downcase)
        raise Error, :authenticated_source_rejected unless SAFE_FORMAT_VALUES.include?(decoded_value.downcase)

        uri.query = "#{decoded_name.downcase}=#{decoded_value.downcase}"
      end

      # An item link may carry the media id the player URL has to repeat.
      # Unknown names still reject the whole URL, so two links are not folded
      # together by dropping the rest of the query.
      def reject_item_query!(uri)
        pairs = uri.query.split(/[&;]/, -1)
        raise Error, :authenticated_source_rejected if pairs.empty? || pairs.size > 4

        kept = pairs.map { |pair| item_pair(pair) }
        raise Error, :authenticated_source_rejected if kept.any?(&:nil?)

        uri.query = kept.join('&')
      end

      def item_pair(pair)
        name, value = pair.split('=', 2)
        decoded_name = fully_decode(name)
        decoded_value = fully_decode(value)
        return nil if decoded_name.blank? || decoded_value.blank?

        decoded_name = decoded_name.downcase
        if decoded_name == 'format'
          return nil unless SAFE_FORMAT_VALUES.include?(decoded_value.downcase)

          return "format=#{decoded_value.downcase}"
        end
        return nil unless ITEM_QUERY.include?(decoded_name)
        return nil unless ITEM_VALUE.match?(decoded_value)

        "#{decoded_name}=#{decoded_value}"
      end

      def reject_asset_query!(uri)
        pairs = uri.query.split('&', -1)
        raise Error, :authenticated_source_rejected if pairs.empty? || pairs.size > ASSET_QUERY_PAIRS

        kept = pairs.map do |pair|
          name, value = pair.split('=', 2)
          decoded_name = fully_decode(name)
          decoded_value = fully_decode(value)
          raise Error, :authenticated_source_rejected if decoded_name.blank? || decoded_value.blank?
          name = decoded_name.downcase
          raise Error, :authenticated_source_rejected unless ASSET_QUERY_NAMES.include?(name)
          raise Error, :authenticated_source_rejected unless safe_asset_value?(name, decoded_value)

          "#{name}=#{decoded_value}"
        end

        uri.query = kept.join('&')
      end

      # The extra parameters used by podcast artwork CDNs have bounded,
      # non-credential values; all other asset parameters keep their existing
      # conservative token-shaped restriction.
      def safe_asset_value?(name, value)
        case name
        when 'max-w', 'max-h'
          value.match?(/\A[0-9]{1,4}\z/) && value.to_i.between?(1, 4096)
        when 'fit'
          %w(crop clip fill max min scale).include?(value)
        when 'auto'
          %w(format compress).include?(value) || %w(format,compress compress,format).include?(value)
        when 'ixlib'
          value.match?(/\Arails-[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,2}\z/)
        else
          ASSET_QUERY_VALUE.match?(value)
        end
      end

      def fully_decode(raw)
        candidate = raw.to_s
        MAX_DECODE.times do
          return nil if malformed_percent?(candidate)

          decoded = decode_component(candidate)
          return nil if decoded.nil?
          return candidate if decoded == candidate

          candidate = decoded
        end
        return nil if candidate.include?('%') || malformed_percent?(candidate)

        candidate
      end

      def malformed_percent?(text)
        text.to_s.match?(%r{%(?![0-9A-Fa-f]{2})})
      end

      def decode_component(value)
        Addressable::URI.unencode_component(value.to_s.tr('+', ' '))
      rescue ArgumentError, Addressable::URI::InvalidURIError
        nil
      end
    end
  end
end
