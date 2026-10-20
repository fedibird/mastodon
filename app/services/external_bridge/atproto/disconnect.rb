# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Local revoke always happens. Remote revoke is attempted only at the
    # stored endpoint, and a failure is recorded instead of treated as success.
    class Disconnect
      def self.call(user:, identity_id:, dns: Dns.live)
        new(user, identity_id, dns).call
      end

      def initialize(user, identity_id, dns)
        @user = user
        @identity_id = identity_id
        @dns = dns
      end

      def call
        raise Error, :account_required if @user.nil?

        identity = ExternalIdentity.find_by(id: @identity_id, user_id: @user.id, provider: Codes::PROVIDER)
        raise Error, :not_found if identity.nil?

        identity.with_lock do
          remote = remote_state(identity)
          revoke_local!(identity)
          identity.update!(
            disconnected_at: Time.current,
            status: 'disconnected',
            revocation_state: remote,
            refresh_started_at: nil,
            access_expires_at: nil
          )
        end
        identity
      end

      private

      def remote_state(identity)
        return 'not_attempted' unless Feature.permitted?(@user)
        return 'not_supported' if identity.revocation_endpoint.blank?

        revoke_remote!(identity)
      end

      def revoke_remote!(identity)
        credential = UserExternalCredential.find_by(id: identity.credential_id, user_id: @user.id)
        return 'remote_revoked' if credential.nil? || credential.revoked_at.present?

        payload = nil
        UserCredentialVault.with_credential(owner: @user, credential: credential, **Codes::CLASSIFICATION) do |sealed|
          payload = sealed.fetch('credentials')
          :ok
        end
        material = SigningKey.for_kid(payload['client_key_id'])
        return 'remote_failed' if material.nil?

        TokenClient.post!(
          url: identity.revocation_endpoint,
          issuer: identity.issuer,
          fields: { 'token' => payload.fetch('refresh_token'), 'token_type_hint' => 'refresh_token', 'client_id' => ClientDocument.client_id },
          dpop_key: OpenSSL::PKey::EC.new(payload.fetch('dpop_private_key')),
          nonce: payload['dpop_nonce'],
          dns: @dns,
          timeout_code: :remote_revocation_failed,
          failure_code: :remote_revocation_failed,
          signing: material
        )
        'remote_revoked'
      rescue Error, UserCredentialVault::Error, OpenSSL::PKey::PKeyError
        'remote_failed'
      end

      def revoke_local!(identity)
        credential = UserExternalCredential.find_by(id: identity.credential_id, user_id: @user.id)
        return if credential.nil? || credential.revoked_at.present?

        UserCredentialVault.revoke!(owner: @user, credential: credential)
      end
    end
  end
end
