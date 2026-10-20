# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Protected-resource and authorization-server metadata. Both must be
    # HTTP 200 JSON with no redirect. Token and PAR URLs stay on the issuer.
    class ServerMetadata
      Metadata = Struct.new(
        :issuer,
        :authorization_endpoint,
        :token_endpoint,
        :par_endpoint,
        :revocation_endpoint,
        :scopes_supported,
        keyword_init: true
      )

      def self.fetch!(issuer, dns:)
        new(dns).fetch!(issuer)
      end

      def self.protected_issuer!(pds_origin, dns:)
        new(dns).protected_issuer!(pds_origin)
      end

      def initialize(dns)
        @dns = dns
      end

      def protected_issuer!(pds_origin)
        result = get("#{pds_origin}/.well-known/oauth-protected-resource")
        return nil if result.code == 404
        raise Error, :discovery_rejected unless result.code == 200 && result.json_type?

        servers = result.json['authorization_servers']
        raise Error, :discovery_rejected unless servers.is_a?(Array) && servers.one? && servers.first.is_a?(String)

        Origin.https_origin!(servers.first)
      end

      def fetch!(issuer)
        result = get("#{issuer}/.well-known/oauth-authorization-server")
        raise Error, :discovery_rejected unless result.code == 200 && result.json_type?

        parse!(result.json, issuer)
      end

      private

      def get(url)
        Http.get!(url, dns: @dns, accept: 'application/json', redirects: :none)
      end

      def parse!(document, issuer)
        raise Error, :issuer_mismatch unless Origin.https_origin!(document['issuer'].to_s) == issuer

        metadata = Metadata.new(
          issuer: issuer,
          authorization_endpoint: bound_endpoint!(document['authorization_endpoint'], issuer),
          token_endpoint: bound_endpoint!(document['token_endpoint'], issuer),
          par_endpoint: bound_endpoint!(document['pushed_authorization_request_endpoint'], issuer),
          revocation_endpoint: optional_endpoint(document['revocation_endpoint'], issuer),
          scopes_supported: scopes!(document['scopes_supported'])
        )
        assert_profile!(document)
        metadata
      end

      def assert_profile!(document)
        raise Error, :discovery_rejected unless document['require_pushed_authorization_requests'] == true
        raise Error, :discovery_rejected unless document['client_id_metadata_document_supported'] == true
        raise Error, :discovery_rejected unless document['authorization_response_iss_parameter_supported'] == true
        raise Error, :discovery_rejected if document['require_request_uri_registration'] == false
        raise Error, :discovery_rejected unless includes?(document['response_types_supported'], 'code')
        raise Error, :discovery_rejected unless includes?(document['grant_types_supported'], 'authorization_code')
        raise Error, :discovery_rejected unless includes?(document['grant_types_supported'], 'refresh_token')
        raise Error, :discovery_rejected unless includes?(document['code_challenge_methods_supported'], 'S256')
        raise Error, :discovery_rejected unless includes?(document['token_endpoint_auth_methods_supported'], 'private_key_jwt')
        raise Error, :discovery_rejected unless includes?(document['token_endpoint_auth_signing_alg_values_supported'], 'ES256')
        raise Error, :discovery_rejected unless includes?(document['dpop_signing_alg_values_supported'], 'ES256')
        raise Error, :discovery_rejected if Array(document['token_endpoint_auth_signing_alg_values_supported']).include?('none')
      end

      def scopes!(value)
        raise Error, :unsupported_scopes unless value.is_a?(Array) && value.all? { |scope| scope.is_a?(String) }
        raise Error, :unsupported_scopes unless value.include?('atproto')

        value
      end

      def includes?(value, expected)
        value.is_a?(Array) && value.include?(expected)
      end

      def bound_endpoint!(value, issuer)
        endpoint = endpoint!(value)
        raise Error, :issuer_mismatch unless Origin.endpoint_origin(endpoint) == issuer

        endpoint
      end

      def optional_endpoint(value, issuer)
        return nil if value.nil?

        bound_endpoint!(value, issuer)
      end

      def endpoint!(value)
        uri = Addressable::URI.parse(value.to_s)
        raise Error, :discovery_rejected if uri.nil? || uri.scheme&.downcase != 'https'
        raise Error, :discovery_rejected if uri.host.blank? || uri.user.present? || uri.password.present? || uri.fragment.present?
        raise Error, :discovery_rejected if uri.query.present?

        uri.to_s
      rescue Addressable::URI::InvalidURIError
        raise Error, :discovery_rejected
      end
    end
  end
end
