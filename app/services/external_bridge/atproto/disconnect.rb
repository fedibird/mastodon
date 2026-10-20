# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Local revoke is committed before any remote revocation request. A failed
    # or interrupted remote call cannot leave the local session usable.
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

        outbound = nil
        already = false
        identity.with_lock do
          identity.reload
          if identity.disconnected_at.present?
            already = true
            next
          end

          outbound = revocation_material(identity)
          revoke_local!(identity)
          identity.update!(
            disconnected_at: Time.current,
            status: 'disconnected',
            revocation_state: outbound ? 'not_attempted' : @skip_reason,
            refresh_started_at: nil,
            access_expires_at: nil
          )
        end
        return identity.reload if already

        record_remote!(identity, outbound) if outbound
        identity.reload
      end

      private

      def revocation_material(identity)
        @skip_reason = 'not_attempted'
        return nil unless Feature.permitted?(@user)

        if identity.revocation_endpoint.blank?
          @skip_reason = 'not_supported'
          return nil
        end

        credential = UserExternalCredential.find_by(id: identity.credential_id, user_id: @user.id)
        return nil if credential.nil? || credential.revoked_at.present?

        payload = sealed(credential)
        outbound = remote_payload(identity, payload)
        return outbound if outbound

        @skip_reason = 'remote_failed'
        nil
      rescue StandardError
        @skip_reason = 'remote_failed'
        nil
      end

      def remote_payload(identity, payload)
        return nil unless payload.is_a?(Hash)

        material = SigningKey.for_kid(payload['client_key_id'])
        refresh = payload['refresh_token']
        pem = payload['dpop_private_key']
        return nil if material.nil? || !refresh.is_a?(String) || refresh.blank? || !pem.is_a?(String) || pem.blank?

        {
          endpoint: identity.revocation_endpoint,
          issuer: identity.issuer,
          refresh_token: refresh,
          dpop_private_key: pem,
          nonce: payload['dpop_nonce'],
          material: material,
        }
      end

      def sealed(credential)
        payload = nil
        UserCredentialVault.with_credential(owner: @user, credential: credential, **Codes::CLASSIFICATION) do |box|
          payload = box.fetch('credentials')
          :ok
        end
        payload
      end

      def record_remote!(identity, outbound)
        state = post_remote(outbound)
        identity.with_lock do
          identity.reload
          # A refresh that already received a rotated token records
          # successor_revoked or successor_revoke_failed. That result is not
          # the same as revoking the predecessor this call submitted.
          next unless identity.disconnected_at.present? && identity.status == 'disconnected' && identity.revocation_state == 'not_attempted'

          identity.update!(revocation_state: state)
        end
      end

      def post_remote(outbound)
        TokenClient.post!(
          url: outbound.fetch(:endpoint),
          issuer: outbound.fetch(:issuer),
          fields: { 'token' => outbound.fetch(:refresh_token), 'token_type_hint' => 'refresh_token', 'client_id' => ClientDocument.client_id },
          dpop_key: OpenSSL::PKey::EC.new(outbound.fetch(:dpop_private_key)),
          nonce: outbound[:nonce],
          dns: @dns,
          timeout_code: :remote_revocation_failed,
          failure_code: :remote_revocation_failed,
          signing: outbound.fetch(:material)
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
