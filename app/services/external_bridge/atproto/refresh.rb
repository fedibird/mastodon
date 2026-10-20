# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Serialized refresh at the bound issuer. A changed issuer, a private
    # address, or a caller-supplied URL never receives the refresh token.
    class Refresh
      MARK = %w(
        issuer_mismatch
        reauthentication_required
        refresh_unacknowledged
        unsupported_scopes
        redirect_rejected
        revoked
      ).freeze

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

        error = nil
        identity.with_lock { error = refresh(identity.reload) }
        raise error if error

        identity.reload
      end

      private

      def refresh(identity)
        guard!(identity)
        precheck!(identity)
        return nil if still_fresh?(identity)

        exchange!(identity)
        nil
      rescue Error => e
        mark!(identity, e) if MARK.include?(e.code)
        e
      rescue UserCredentialVault::Revoked, UserCredentialVault::Expired
        mark!(identity, Error.new(:revoked))
        Error.new(:revoked)
      rescue UserCredentialVault::Error
        Error.new(:vault_unavailable)
      end

      def guard!(identity)
        raise Error, :revoked if identity.disconnected_at.present? || identity.status == 'disconnected'
        raise Error, :reauthentication_required if identity.status == 'reauthentication_required'
        raise Error, :refresh_unacknowledged if identity.refresh_started_at.present?
      end

      def precheck!(identity)
        @confirmed = Discovery.confirm!(did: identity.subject, issuer: identity.issuer, dns: @dns)
        metadata = ServerMetadata.fetch!(identity.issuer, dns: @dns)
        raise Error, :reauthentication_required unless metadata.token_endpoint == identity.token_endpoint
      end

      def still_fresh?(identity)
        return false if identity.access_expires_at.nil? || identity.access_expires_at <= 60.seconds.from_now

        apply_confirmation!(identity)
        identity.last_checked_at = Time.current
        identity.save!
        true
      end

      def exchange!(identity)
        credential = UserExternalCredential.find_by(id: identity.credential_id, user_id: @user.id)
        raise Error, :revoked if credential.nil? || credential.revoked_at.present?

        identity.update!(refresh_started_at: Time.current)
        payload = sealed_credentials(credential)
        material = SigningKey.for_kid(payload['client_key_id'])
        raise Error, :reauthentication_required if material.nil? || payload['token_endpoint'] != identity.token_endpoint

        exchanged = TokenClient.post!(
          url: identity.token_endpoint,
          issuer: identity.issuer,
          fields: { 'grant_type' => 'refresh_token', 'refresh_token' => payload.fetch('refresh_token'), 'client_id' => ClientDocument.client_id },
          dpop_key: OpenSSL::PKey::EC.new(payload.fetch('dpop_private_key')),
          nonce: payload['dpop_nonce'],
          dns: @dns,
          timeout_code: :refresh_unacknowledged,
          failure_code: :reauthentication_required,
          signing: material
        )
        granted, partial = Scopes.accept!(identity.granted_scopes, exchanged.fetch('json')['scope'])
        replace!(identity, credential, payload, exchanged, granted, partial, material)
      end

      def sealed_credentials(credential)
        payload = nil
        UserCredentialVault.with_credential(owner: @user, credential: credential, **Codes::CLASSIFICATION) do |sealed|
          payload = sealed.fetch('credentials')
          :ok
        end
        payload
      end

      def replace!(identity, credential, payload, exchanged, granted, partial, material) # rubocop:disable Metrics/ParameterLists -- rotation inputs stay explicit
        tokens = exchanged.fetch('json')
        expires_in = [tokens['expires_in'].to_i, 30.minutes.to_i].min
        raise Error, :reauthentication_required unless expires_in.positive? && tokens['token_type'].to_s.casecmp('dpop').zero?

        generation = identity.refresh_generation.to_i + 1
        secrets = SessionStore.credentials(
          tokens: tokens,
          pem: payload.fetch('dpop_private_key'),
          nonce: exchanged.fetch('nonce'),
          endpoint: identity.token_endpoint,
          issuer: identity.issuer,
          kid: material.kid,
          scopes: granted,
          generation: generation,
          expires_at: expires_in.seconds.from_now
        )
        UserCredentialVault.replace!(owner: @user, credential: credential, credentials: secrets, **Codes::CLASSIFICATION)
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

      def apply_confirmation!(identity)
        identity.resource_origin = @confirmed.fetch(:resource_origin)
        identity.handle = @confirmed[:handle] if @confirmed[:handle].present?
      end

      def mark!(identity, error)
        return if identity.disconnected_at.present? || identity.status == 'disconnected'

        identity.update!(
          status: 'reauthentication_required',
          last_error_code: error.code,
          refresh_started_at: nil
        )
      end
    end
  end
end
