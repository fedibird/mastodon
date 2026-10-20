# frozen_string_literal: true

module ExternalBridge
  # AT Protocol OAuth identity connection.
  #
  # There is no Ruby SDK that implements this profile (PAR, PKCE S256, DPoP
  # nonces, private_key_jwt, and DID/issuer binding) without dropping one of
  # those checks. The reference client is the TypeScript @atproto/oauth-client.
  # Adding that runtime would not share this process's SSRF or vault boundary.
  # ES256 is signed with OpenSSL. Generic OAuth libraries are not used.
  module Atproto
    module Codes
      PROVIDER = 'bluesky'
      PURPOSE = 'identity'
      CREDENTIAL_TYPE = 'oauth_session'
      CLASSIFICATION = {
        provider: PROVIDER,
        purpose: PURPOSE,
        credential_type: CREDENTIAL_TYPE,
      }.freeze

      CODES = %w(
        account_required
        authorization_failed
        authorization_rejected
        discovery_rejected
        feature_disabled
        issuer_mismatch
        not_found
        partial_scopes
        private_address
        reauthentication_required
        redirect_rejected
        refresh_unacknowledged
        remote_revocation_failed
        revoked
        signing_key_unavailable
        stale_callback
        state_rejected
        tester_only
        unsupported_scopes
        vault_unavailable
      ).freeze

      module_function

      def safe!(code)
        string = code.to_s
        raise Error, :authorization_failed unless CODES.include?(string)

        string
      end
    end
  end
end
