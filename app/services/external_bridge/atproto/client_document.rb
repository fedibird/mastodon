# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Public client metadata. The client_id is this document's HTTPS URL.
    # Production refuses a missing key, HTTP, a port, or a local hostname.
    class ClientDocument
      DECLARED_SCOPE = 'atproto'

      def self.configured?
        SigningKey.configured? && origin.present?
      end

      def self.origin
        return nil unless Rails.configuration.x.use_https

        host = Rails.configuration.x.web_domain.to_s.downcase
        return nil if host.blank? || host.include?(':') || Origin.blocked_host?(host)

        "https://#{host}"
      end

      def self.client_id
        "#{origin}/oauth/bluesky/client-metadata"
      end

      def self.redirect_uri
        "#{origin}/settings/external_services/bluesky/callback"
      end

      def self.jwks_uri
        "#{origin}/oauth/bluesky/jwks"
      end

      def self.metadata
        return nil unless configured?

        {
          'client_id' => client_id,
          'application_type' => 'web',
          'client_name' => Setting.site_title.presence || 'Fedibird',
          'client_uri' => "#{origin}/",
          'grant_types' => %w(authorization_code refresh_token),
          'response_types' => ['code'],
          'redirect_uris' => [redirect_uri],
          'scope' => DECLARED_SCOPE,
          'token_endpoint_auth_method' => 'private_key_jwt',
          'token_endpoint_auth_signing_alg' => 'ES256',
          'dpop_bound_access_tokens' => true,
          'jwks_uri' => jwks_uri,
        }
      end

      def self.jwks
        return nil unless configured?

        { 'keys' => SigningKey.public_jwks }
      end
    end
  end
end
