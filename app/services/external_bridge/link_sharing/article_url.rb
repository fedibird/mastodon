# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Public article permalink stored on a reference note.
    #
    # This is not ExternalBridge::RSS::CanonicalURL. Feed fetch URLs still
    # allow only format=rss|atom|xml|feed. An article URL may carry a short
    # public permalink query. Credential names, userinfo, private IP literals,
    # and percent-encoding that hides those names are rejected. Unknown query
    # names are rejected too.
    class ArticleURL
      INTEGER_NAMES = %w(p page_id post_id).freeze
      SLUG_OR_INTEGER_NAMES = %w(id name).freeze
      SECRET_NAMES = %w(
        token access_token refresh_token id_token key api_key apikey
        auth authorization signature sig password passwd secret credential
        credentials session jwt code state nonce oauth bearer
      ).freeze
      MAX_PAIRS = 3
      MAX_DECODE = 8

      def self.normalize!(value)
        new(value).normalize!
      end

      def initialize(value)
        @value = value.to_s
      end

      def normalize!
        uri = parse!
        reject_userinfo!(uri)
        reject_private_literal!(uri)
        uri.query = normalize_query!(uri.query)
        uri.scheme = uri.scheme.downcase
        uri.host = uri.host.downcase
        uri.port = nil if uri.port == uri.default_port
        uri.fragment = nil
        uri.path = '' if uri.path == '/'
        reject_path!(uri.path)
        key = uri.to_s
        raise Error, :unsupported_url if key.bytesize > RSS::Limits::MAX_KEY_BYTES

        key
      end

      private

      def parse!
        uri = Addressable::URI.parse(@value)
        raise Error, :unsupported_url if uri.nil?
        raise Error, :unsupported_url unless %w(http https).include?(uri.scheme&.downcase)
        raise Error, :unsupported_url if uri.host.blank?
        raise Error, :unsupported_url if uri.host.match?(/[[:cntrl:]\s]/)

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

      def reject_path!(path)
        decoded = fully_decode(path.to_s)
        raise Error, :unsupported_url if decoded.nil?
        raise Error, :unsupported_url if decoded.match?(/[[:cntrl:]\\]/)

        segments = decoded.split('/')
        raise Error, :unsupported_url if segments.include?('..')
      end

      def normalize_query!(query)
        return nil if query.nil?
        raise Error, :authenticated_source_rejected if query.blank? || query.include?(';') || malformed_percent?(query)

        pairs = query.split('&').map { |pair| normalize_pair!(pair) }
        raise Error, :authenticated_source_rejected if pairs.empty? || pairs.size > MAX_PAIRS
        raise Error, :authenticated_source_rejected if pairs.map(&:first).uniq.size != pairs.size

        pairs.sort_by(&:first).map { |name, value| "#{name}=#{value}" }.join('&')
      end

      def normalize_pair!(pair)
        name, value = pair.split('=', 2)
        raise Error, :authenticated_source_rejected if value.nil?

        decoded_name = fully_decode(name)
        decoded_value = fully_decode(value)
        raise Error, :authenticated_source_rejected if decoded_name.blank? || decoded_value.blank?
        raise Error, :authenticated_source_rejected if secret_name?(decoded_name)

        canonical_name = decoded_name.downcase
        [canonical_name, canonical_value!(canonical_name, decoded_value)]
      end

      def secret_name?(name)
        segments = name.downcase.split(/[^a-z0-9]+/).reject(&:empty?)
        segments.any? { |segment| SECRET_NAMES.include?(segment) } || SECRET_NAMES.include?(name.downcase)
      end

      def canonical_value!(name, value)
        if INTEGER_NAMES.include?(name) || (SLUG_OR_INTEGER_NAMES.include?(name) && integer_value?(value))
          raise Error, :authenticated_source_rejected unless integer_value?(value)

          return value.sub(/\A0+/, '')
        end

        raise Error, :authenticated_source_rejected unless SLUG_OR_INTEGER_NAMES.include?(name)
        raise Error, :authenticated_source_rejected unless public_slug?(value)

        value
      end

      def integer_value?(value)
        value.match?(/\A[1-9][0-9]{0,17}\z/) || value.match?(/\A0+[1-9][0-9]{0,17}\z/)
      end

      def public_slug?(value)
        return false unless value.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]{0,79}\z/)
        return false unless value.match?(/[A-Za-z]/)
        return false if value.length >= 24 && value.exclude?('-') && value.exclude?('_')
        return false if value.include?('eyJ')

        true
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
