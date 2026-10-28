# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # The id inside an ActivityStreams document. This is an identifier, not
      # a fetch URL: fragments and non-credential query strings stay exactly
      # as the document sent them. Passing the safety checks does not mean
      # the identifier was dereferenced.
      class ObjectId
        CREDENTIAL_NAMES = %w(access_token auth key password sig signature token viewkey).freeze

        def self.preserve!(value)
          new(value).preserve!
        end

        def initialize(value)
          @value = value
        end

        def preserve!
          text = original_string!
          uri = parsed_uri!(text)
          reject_userinfo!(uri)
          reject_private_literal!(uri)
          reject_credential_query!(uri)
          text
        end

        private

        def original_string!
          raise Error, :unsupported_url unless @value.is_a?(String)
          raise Error, :unsupported_url if @value.empty? || @value.bytesize > RSS::Limits::MAX_KEY_BYTES
          raise Error, :unsupported_url if @value.match?(/[\x00-\x20\x7f]/)

          @value
        end

        def parsed_uri!(text)
          uri = Addressable::URI.parse(text)
          raise Error, :unsupported_url if uri.nil? || uri.host.blank?
          raise Error, :unsupported_url unless uri.scheme.to_s.match?(/\Ahttps?\z/i)

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

        def reject_credential_query!(uri)
          return if uri.query.nil?

          unsafe = uri.query.split(/[&;]/).any? do |pair|
            CREDENTIAL_NAMES.include?(decoded_name(pair.split('=', 2).first))
          end
          raise Error, :authenticated_source_rejected if unsafe
        end

        def decoded_name(raw)
          candidate = raw.to_s
          3.times do
            decoded = unencode(candidate)
            break if decoded.nil? || decoded == candidate

            candidate = decoded
          end
          candidate.downcase
        end

        def unencode(text)
          Addressable::URI.unencode_component(text.to_s)
        rescue ArgumentError, Addressable::URI::InvalidURIError
          nil
        end
      end
    end
  end
end
