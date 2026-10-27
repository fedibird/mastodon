# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Image URL for a player poster.
    #
    # A path such as `/original.mp4/plain/.../rs:fit:320:240` is an image
    # transform, not a video file. `hash`, `validto`, `hdnea`, and `exp` are
    # the only query names treated as a rotating signature. They are kept on
    # the fetch URL and omitted from the logical URL. Every other query name
    # stays on both, so two images that differ by a non-signature parameter
    # stay different. Credential-shaped names other than those four fail.
    class PosterURL
      Pair = Struct.new(:fetch, :logical, keyword_init: true)
      SIGNATURE = %w(hash validto hdnea exp).freeze
      NAME = /\A[a-z0-9_-]{1,32}\z/.freeze
      VALUE = /\A[A-Za-z0-9._~=-]{1,512}\z/.freeze
      CREDENTIAL = /token|key|sig|auth|credential|password|passwd|secret|session|jwt|access|expires|expiry|nonce/i.freeze
      LOCAL_HOST = /\A(localhost|.*\.(local|localhost|internal))\z/i.freeze
      MAX_PAIRS = 8

      def self.pair(value)
        new(value).pair
      end

      def self.fetch!(value)
        found = pair(value)
        return found.fetch if found

        raise Error, :unsupported_url
      end

      def initialize(value)
        @value = value.to_s
      end

      def pair
        plain = MediaURL.normalize(@value)
        return Pair.new(fetch: plain, logical: plain) if plain

        signed_pair
      end

      private

      def signed_pair
        uri = parse
        return nil if uri.nil? || unsafe_host?(uri)

        pairs = query_pairs(uri)
        return nil if pairs.blank? || pairs.any?(&:nil?)
        return nil if pairs.none? { |name, _value| SIGNATURE.include?(name) }

        fetch = canonical(uri, pairs)
        logical = canonical(uri, pairs.reject { |name, _value| SIGNATURE.include?(name) })
        return nil if fetch.blank? || logical.blank?

        Pair.new(fetch: fetch, logical: logical)
      end

      def parse
        text = @value.strip
        return nil if text.blank? || text.match?(/[\s\\]/)
        return nil if text.match?(/\A(?:javascript|data|blob|file|vbscript):/i)

        uri = Addressable::URI.parse(text)
        return nil if uri.nil? || uri.host.blank? || uri.user.present? || uri.password.present?
        return nil unless %w(http https).include?(uri.scheme&.downcase)

        uri
      rescue Addressable::URI::InvalidURIError
        nil
      end

      def query_pairs(uri)
        return [] if uri.query.nil?
        return nil if uri.query.blank? || malformed?(uri.query)

        rows = uri.query.split('&', -1)
        return nil if rows.empty? || rows.size > MAX_PAIRS

        seen = {}
        rows.map { |row| one_pair(row, seen) }
      end

      def one_pair(row, seen)
        name, value = row.split('=', 2)
        decoded_name = decode(name)
        decoded_value = decode(value)
        return nil if decoded_name.blank? || decoded_value.blank?

        decoded_name = decoded_name.downcase
        return nil unless NAME.match?(decoded_name) && VALUE.match?(decoded_value)
        return nil if !SIGNATURE.include?(decoded_name) && CREDENTIAL.match?(decoded_name)
        return nil if SIGNATURE.include?(decoded_name) && seen[decoded_name]

        seen[decoded_name] = true if SIGNATURE.include?(decoded_name)
        [decoded_name, decoded_value]
      rescue ArgumentError
        nil
      end

      def canonical(uri, pairs)
        return nil if pairs.any?(&:nil?)

        copy = uri.dup
        copy.scheme = copy.scheme.downcase
        copy.host = copy.host.downcase
        copy.port = nil if copy.port == copy.default_port
        copy.fragment = nil
        copy.query = pairs.empty? ? nil : pairs.map { |name, value| "#{name}=#{value}" }.join('&')
        text = copy.to_s
        return nil if text.bytesize > Limits::MAX_KEY_BYTES

        text
      end

      def unsafe_host?(uri)
        host = uri.host.to_s
        return true if LOCAL_HOST.match?(host)

        address = IPAddr.new(host)
        PrivateAddressCheck.private_address?(address)
      rescue IPAddr::InvalidAddressError
        false
      end

      def decode(raw)
        candidate = raw.to_s
        CanonicalURL::MAX_DECODE.times do
          return nil if malformed?(candidate)

          decoded = Addressable::URI.unencode_component(candidate.tr('+', ' '))
          return candidate if decoded == candidate

          candidate = decoded
        end
        nil
      rescue ArgumentError, Addressable::URI::InvalidURIError
        nil
      end

      def malformed?(text)
        text.to_s.match?(%r{%(?![0-9A-Fa-f]{2})})
      end
    end
  end
end
