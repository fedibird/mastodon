# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Serialized refresh at the bound issuer. The in-flight marker is committed
    # before the refresh token is sent, and the token response subject must be
    # this identity's DID before the vault row is replaced.
    #
    # A discovery or transport failure before that request is recorded and
    # retried. It does not change status. A confirmed issuer or token-endpoint
    # mismatch still requires the user to sign in again.
    class Refresh
      DEFINITE_PRECHECK = %w(issuer_mismatch reauthentication_required unsupported_scopes).freeze
      RETRYABLE_PRECHECK = %w(discovery_rejected private_address redirect_rejected).freeze

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

        Feature.require!(@user)
        identity = ExternalIdentity.find_by(id: @identity_id, user_id: @user.id, provider: Codes::PROVIDER)
        raise Error, :not_found if identity.nil?

        raise Error, :refresh_unacknowledged if observe!(identity)

        begin
          precheck!(identity)
        rescue Error => e
          classify_precheck!(identity, e)
          raise
        end

        claim!(identity)
        return identity.reload if @fresh

        exchanged = post!(identity)
        finish_exchange!(identity, exchanged)
        identity.reload
      end

      private

      def observe!(identity)
        unknown = false
        identity.with_lock do
          identity.reload
          raise Error, :revoked if disconnected?(identity)
          raise Error, :reauthentication_required if identity.status == 'reauthentication_required'

          if identity.refresh_started_at.present?
            note_unknown!(identity)
            unknown = true
          end
        end
        unknown
      end

      def precheck!(identity)
        @confirmed = Discovery.confirm!(did: identity.subject, issuer: identity.issuer, dns: @dns)
        @metadata = ServerMetadata.fetch!(identity.issuer, dns: @dns)
        raise Error, :reauthentication_required unless @metadata.token_endpoint == identity.token_endpoint
      end

      def claim!(identity)
        unknown = false
        begin
          identity.with_lock do
            identity.reload
            raise Error, :revoked if disconnected?(identity)
            raise Error, :reauthentication_required if identity.status == 'reauthentication_required'

            if identity.refresh_started_at.present?
              note_unknown!(identity)
              unknown = true
              next
            end

            raise Error, :reauthentication_required unless @metadata.token_endpoint == identity.token_endpoint

            if fresh?(identity)
              @fresh = true
              next
            end

            @bundle = prepare!(identity)
            @session_stamp = identity.oauth_session_stamp
            identity.update!(refresh_started_at: Time.current)
          end
        rescue Error => e
          mark_unclaimed!(identity, e)
          raise
        rescue UserCredentialVault::Revoked, UserCredentialVault::Expired
          mark_unclaimed!(identity, Error.new(:revoked))
          raise Error, :revoked
        rescue UserCredentialVault::Error
          raise Error, :vault_unavailable
        end
        raise Error, :refresh_unacknowledged if unknown
      end

      def post!(identity)
        bundle = @bundle
        TokenClient.post!(
          url: bundle.fetch(:endpoint),
          issuer: bundle.fetch(:issuer),
          fields: { 'grant_type' => 'refresh_token', 'refresh_token' => bundle.fetch(:payload).fetch('refresh_token'), 'client_id' => ClientDocument.client_id },
          dpop_key: OpenSSL::PKey::EC.new(bundle.fetch(:payload).fetch('dpop_private_key')),
          nonce: bundle.fetch(:payload)['dpop_nonce'],
          dns: @dns,
          timeout_code: :refresh_unacknowledged,
          failure_code: :reauthentication_required,
          signing: bundle.fetch(:material)
        )
      rescue Error => e
        settle_claimed!(identity, e)
        raise
      end

      def finish_exchange!(identity, exchanged)
        identity.with_lock do
          identity.reload
          raise Error, :revoked if disconnected?(identity)
          raise Error, :refresh_unacknowledged if identity.refresh_started_at.blank?
          raise Error, :reauthentication_required unless identity.token_endpoint == @bundle.fetch(:endpoint)

          tokens = exchanged.fetch('json')
          bind_subject!(identity, tokens)
          granted, partial = Scopes.accept!(identity.granted_scopes, tokens['scope'])
          replace!(identity, exchanged, granted, partial)
        end
      rescue Error => e
        # A disconnect that won the lock must not leave the rotated refresh
        # token unrevoked. The predecessor revoke is not the successor revoke.
        successor = discard_rotated_token(exchanged)
        note_successor_revocation!(identity, successor) if e.code == 'revoked'
        settle_claimed!(identity, e)
        raise
      end

      def prepare!(identity)
        credential = UserExternalCredential.find_by(id: identity.credential_id, user_id: @user.id)
        raise Error, :revoked if credential.nil? || credential.revoked_at.present?

        payload = sealed_credentials(credential)
        material = SigningKey.for_kid(payload['client_key_id'])
        raise Error, :reauthentication_required if material.nil? || payload['token_endpoint'] != identity.token_endpoint

        {
          credential: credential,
          payload: payload,
          material: material,
          endpoint: identity.token_endpoint,
          issuer: identity.issuer,
          revocation_endpoint: identity.revocation_endpoint,
        }
      end

      def bind_subject!(identity, tokens)
        sub = tokens['sub'].to_s
        raise Error, :authorization_rejected unless Did.valid?(sub) && sub == identity.subject

        returned = tokens['iss'].presence || tokens['issuer'].presence
        return if returned.blank?

        origin = Origin.of(returned)
        raise Error, :issuer_mismatch unless origin == identity.issuer
      end

      def sealed_credentials(credential)
        payload = nil
        UserCredentialVault.with_credential(owner: @user, credential: credential, **Codes::CLASSIFICATION) do |sealed|
          payload = sealed.fetch('credentials')
          :ok
        end
        payload
      end

      def replace!(identity, exchanged, granted, partial)
        tokens = exchanged.fetch('json')
        expires_in = [tokens['expires_in'].to_i, 30.minutes.to_i].min
        raise Error, :reauthentication_required unless expires_in.positive? && tokens['token_type'].to_s.casecmp('dpop').zero?

        generation = identity.refresh_generation.to_i + 1
        secrets = SessionStore.credentials(
          tokens: tokens,
          pem: @bundle.fetch(:payload).fetch('dpop_private_key'),
          nonce: exchanged.fetch('nonce'),
          endpoint: identity.token_endpoint,
          issuer: identity.issuer,
          kid: @bundle.fetch(:material).kid,
          scopes: granted,
          generation: generation,
          expires_at: expires_in.seconds.from_now
        )
        UserCredentialVault.replace!(owner: @user, credential: @bundle.fetch(:credential), credentials: secrets, **Codes::CLASSIFICATION)
        apply_confirmation!(identity)
        identity.update!(
          granted_scopes: granted,
          status: partial ? 'warning' : 'connected',
          last_error_code: partial ? 'partial_scopes' : nil,
          last_checked_at: Time.current,
          refresh_generation: generation,
          refresh_started_at: nil,
          access_expires_at: expires_in.seconds.from_now
        )
      end

      def fresh?(identity)
        return false if identity.access_expires_at.nil? || identity.access_expires_at <= 60.seconds.from_now

        apply_confirmation!(identity)
        identity.last_checked_at = Time.current
        identity.last_error_code = nil if RETRYABLE_PRECHECK.include?(identity.last_error_code)
        identity.save!
        true
      end

      def apply_confirmation!(identity)
        identity.resource_origin = @confirmed.fetch(:resource_origin)
        identity.handle = @confirmed[:handle] if @confirmed[:handle].present?
      end

      def discard_rotated_token(exchanged)
        tokens = exchanged.is_a?(Hash) ? exchanged['json'] : nil
        refresh = tokens.is_a?(Hash) ? tokens['refresh_token'].to_s : ''
        endpoint = @bundle&.fetch(:revocation_endpoint, nil)
        return nil if refresh.blank? || endpoint.blank?

        TokenClient.post!(
          url: endpoint,
          issuer: @bundle.fetch(:issuer),
          fields: { 'token' => refresh, 'token_type_hint' => 'refresh_token', 'client_id' => ClientDocument.client_id },
          dpop_key: OpenSSL::PKey::EC.new(@bundle.fetch(:payload).fetch('dpop_private_key')),
          nonce: exchanged.fetch('nonce'),
          dns: @dns,
          timeout_code: :refresh_unacknowledged,
          failure_code: :reauthentication_required,
          signing: @bundle.fetch(:material)
        )
        'successor_revoked'
      rescue Error, OpenSSL::PKey::PKeyError
        'successor_revoke_failed'
      end

      # Records only the successor attempt. It does not clear disconnected_at
      # or replace the vault row. If this process dies after the token
      # response and before this POST, the new token was never stored and
      # cannot be revoked later.
      def note_successor_revocation!(identity, result)
        return unless %w(successor_revoked successor_revoke_failed).include?(result)

        stamp = @session_stamp
        identity.with_lock do
          identity.reload
          next unless disconnected?(identity) && identity.oauth_session_stamp == stamp

          identity.update!(revocation_state: result)
        end
      end

      def settle_claimed!(identity, error)
        identity.with_lock do
          identity.reload
          next if disconnected?(identity) || identity.refresh_started_at.blank?

          revoke_local!(identity)
          identity.update!(status: 'reauthentication_required', last_error_code: safe_code(error))
        end
      end

      def mark_unclaimed!(identity, error)
        identity.with_lock do
          identity.reload
          next if disconnected?(identity) || identity.refresh_started_at.present? || identity.status == 'reauthentication_required'

          identity.update!(status: 'reauthentication_required', last_error_code: safe_code(error), refresh_started_at: nil)
        end
      end

      def classify_precheck!(identity, error)
        if DEFINITE_PRECHECK.include?(error.code.to_s)
          mark_unclaimed!(identity, error)
        else
          note_retryable!(identity, error)
        end
      end

      # No blocking backoff. The next check may run immediately once discovery
      # succeeds, and last_error_code stays visible on the settings page.
      def note_retryable!(identity, error)
        identity.with_lock do
          identity.reload
          next if disconnected?(identity) || identity.refresh_started_at.present? || identity.status == 'reauthentication_required'

          identity.update!(last_error_code: safe_code(error), last_checked_at: Time.current)
        end
      end

      def revoke_local!(identity)
        credential = UserExternalCredential.find_by(id: identity.credential_id, user_id: @user.id)
        return if credential.nil? || credential.revoked_at.present?

        UserCredentialVault.revoke!(owner: @user, credential: credential)
      end

      def note_unknown!(identity)
        ExternalIdentity.where(id: identity.id, refresh_generation: identity.refresh_generation, disconnected_at: nil).where.not(refresh_started_at: nil).update_all(
          status: 'reauthentication_required',
          last_error_code: 'refresh_unacknowledged',
          updated_at: Time.current
        )
      end

      def disconnected?(identity)
        identity.disconnected_at.present? || identity.status == 'disconnected'
      end

      def safe_code(error)
        code = error.code.to_s
        Codes::CODES.include?(code) ? code : 'authorization_failed'
      end
    end
  end
end
