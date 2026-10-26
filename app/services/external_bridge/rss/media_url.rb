# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Public http(s) URL for an article image, video, or audio file.
    #
    # Credential-shaped query names are rejected. Other query names are
    # rejected too: only a short list of cache-buster and size parameters is
    # kept. javascript:, data:, and private address literals never become a
    # stored candidate. DNS answers and redirects are checked again by Request
    # when Fedibird itself fetches. A browser that plays a remote video can
    # still be redirected somewhere this check did not see.
    class MediaURL
      QUERY_NAMES = %w(w h width height size s format quality q fit crop auto fm dpr cb v ver version rev r t ts resize ixlib).freeze
      QUERY_VALUE = /\A[A-Za-z0-9._-]{1,64}\z/.freeze
      MAX_PAIRS = 6
      CREDENTIAL = /token|key|sig|auth|credential|password|passwd|secret|session|jwt|access|expires|expiry|nonce/i.freeze
      LOCAL_HOST = /\A(localhost|.*\.(local|localhost|internal))\z/i.freeze

      def self.normalize(value)
        new(value).normalize
      end

      def self.normalize!(value)
        normalize(value) || raise(Error, :unsupported_url)
      end

      def initialize(value)
        @value = value.to_s
      end

      def normalize
        uri = parse
        return nil if uri.nil?
        return nil if uri.user.present? || uri.password.present?
        return nil unless reject_query(uri)
        return nil if private_host?(uri.host)

        uri.scheme = uri.scheme.downcase
        uri.host = uri.host.downcase
        uri.port = nil if uri.port == uri.default_port
        uri.fragment = nil
        key = uri.to_s
        return nil if key.bytesize > Limits::MAX_KEY_BYTES

        key
      end

      private

      def parse
        text = @value.strip
        return nil if text.blank? || text.match?(/[\s\\]/)
        return nil if text.match?(/\A(?:javascript|data|blob|file|vbscript):/i)

        uri = Addressable::URI.parse(text)
        return nil if uri.nil? || uri.host.blank?
        return nil unless %w(http https).include?(uri.scheme&.downcase)

        uri
      rescue Addressable::URI::InvalidURIError
        nil
      end

      def reject_query(uri)
        return true if uri.query.nil?
        return false if uri.query.blank? || malformed_percent?(uri.query)

        pairs = uri.query.split('&', -1)
        return false if pairs.empty? || pairs.size > MAX_PAIRS

        kept = pairs.map { |pair| keep_pair(pair) }
        return false if kept.any?(&:nil?)

        uri.query = kept.join('&')
        true
      end

      def keep_pair(pair)
        name, value = pair.split('=', 2)
        decoded_name = fully_decode(name)
        decoded_value = fully_decode(value)
        return nil if decoded_name.blank? || decoded_value.blank?
        return nil if CREDENTIAL.match?(decoded_name)
        return nil unless QUERY_NAMES.include?(decoded_name.downcase)
        return nil unless QUERY_VALUE.match?(decoded_value)

        "#{decoded_name.downcase}=#{decoded_value}"
      end

      def private_host?(host)
        return true if LOCAL_HOST.match?(host.to_s)

        address = IPAddr.new(host)
        PrivateAddressCheck.private_address?(address)
      rescue IPAddr::InvalidAddressError
        false
      end

      def fully_decode(raw)
        candidate = raw.to_s
        CanonicalURL::MAX_DECODE.times do
          return nil if malformed_percent?(candidate)

          decoded = Addressable::URI.unencode_component(candidate.tr('+', ' '))
          return candidate if decoded == candidate

          candidate = decoded
        end
        nil
      rescue ArgumentError, Addressable::URI::InvalidURIError
        nil
      end

      def malformed_percent?(text)
        text.to_s.match?(%r{%(?![0-9A-Fa-f]{2})})
      end
    end
  end
end
