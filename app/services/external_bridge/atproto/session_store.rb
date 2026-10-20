# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Commits a vault row and an identity together. A stale or disconnected
    # attempt rolls back both.
    class SessionStore
      MAX_TOKEN = 8_000

      def self.save!(user:, attempt:, subject:, handle:, resource_origin:, granted_scopes:, partial:, secrets:) # rubocop:disable Metrics/ParameterLists -- commit fields stay named
        new(user, attempt).save!(subject, handle, resource_origin, granted_scopes, partial, secrets)
      end

      def initialize(user, attempt)
        @user = user
        @attempt = attempt
      end

      def save!(subject, handle, resource_origin, granted_scopes, partial, secrets) # rubocop:disable Metrics/ParameterLists -- commit fields stay explicit
        ExternalIdentity.transaction do
          lock!(subject)
          identity = ExternalIdentity.lock.find_by(user_id: @user.id, provider: Codes::PROVIDER, subject: subject)
          raise Error, :stale_callback if superseded?(identity)

          revoke_previous!(identity)
          credential = store_credential!(secrets)
          identity = assign!(identity, subject, handle, resource_origin, granted_scopes, partial, credential, secrets)
          retain_attempt!
          identity
        end
      rescue UserCredentialVault::ConfigurationError
        raise Error, :vault_unavailable
      rescue ArgumentError
        raise Error, :authorization_rejected
      end

      def self.credentials(tokens:, pem:, nonce:, endpoint:, issuer:, kid:, scopes:, generation:, expires_at:) # rubocop:disable Metrics/ParameterLists -- vault fields stay named
        values = {
          'refresh_token' => tokens['refresh_token'].to_s,
          'access_token' => tokens['access_token'].to_s,
          'access_expires_at' => expires_at.iso8601,
          'dpop_private_key' => pem,
          'dpop_nonce' => nonce.to_s,
          'token_endpoint' => endpoint,
          'issuer' => issuer,
          'client_key_id' => kid.to_s,
          'granted_scope' => scopes.join(' '),
          'session_generation' => generation.to_s,
        }
        values.each do |name, value|
          raise Error, :authorization_rejected if !value.is_a?(String) || value.empty? || value.bytesize > MAX_TOKEN || value.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)

          encoded = value.dup
          encoded.force_encoding(Encoding::UTF_8)
          raise Error, :authorization_rejected unless encoded.valid_encoding?

          values[name] = encoded
        end
        values
      end

      private

      def lock!(subject)
        hi, lo = Digest::SHA256.digest("#{@user.id}:#{subject}").unpack('l>l>')
        ExternalIdentity.connection.select_value("SELECT pg_advisory_xact_lock(#{hi.to_i}, #{lo.to_i})")
      end

      def superseded?(identity)
        return false if identity.nil?
        return true if identity.disconnected_at && identity.disconnected_at >= @attempt.created_at

        identity.bound_attempt_id.present? && identity.bound_attempt_id > @attempt.id && identity.disconnected_at.nil?
      end

      def revoke_previous!(identity)
        return if identity.nil? || identity.credential_id.nil?

        credential = UserExternalCredential.find_by(id: identity.credential_id, user_id: @user.id)
        return if credential.nil? || credential.revoked_at.present?

        UserCredentialVault.revoke!(owner: @user, credential: credential)
      end

      def store_credential!(secrets)
        UserCredentialVault.store!(
          owner: @user,
          provider: Codes::PROVIDER,
          purpose: Codes::PURPOSE,
          credential_type: Codes::CREDENTIAL_TYPE,
          credentials: secrets
        )
      end

      def assign!(identity, subject, handle, resource_origin, granted_scopes, partial, credential, secrets) # rubocop:disable Metrics/ParameterLists -- identity columns stay explicit
        row = identity || ExternalIdentity.new(user_id: @user.id, provider: Codes::PROVIDER, subject: subject)
        row.assign_attributes(
          issuer: @attempt.issuer,
          resource_origin: resource_origin,
          handle: handle,
          credential_id: credential.id,
          granted_scopes: granted_scopes,
          disconnected_at: nil,
          terms_state: 'approved',
          status: partial ? 'warning' : 'connected',
          session_bound_at: Time.current,
          bound_attempt_id: @attempt.id,
          last_checked_at: Time.current,
          last_error_code: partial ? 'partial_scopes' : nil,
          revocation_state: nil,
          token_endpoint: @attempt.token_endpoint,
          revocation_endpoint: @attempt.revocation_endpoint,
          refresh_generation: 0,
          refresh_started_at: nil,
          access_expires_at: access_expiry(secrets)
        )
        row.save!
        row
      end

      def access_expiry(secrets)
        Time.iso8601(secrets.fetch('access_expires_at'))
      end

      # The sliding window counts rows by created_at, including successes.
      # PKCE and the DPoP private key are replaced with a tombstone. If cleanup
      # removed the row during the exchange, the same created_at is inserted again.
      def retain_attempt!
        cleared = AttemptBox.tombstone(@attempt)
        consumed_at = @attempt.consumed_at || Time.current
        updated = ExternalOauthAttempt.where(id: @attempt.id).update_all(
          consumed_at: consumed_at,
          encrypted_secrets: cleared,
          updated_at: Time.current
        )
        return if updated == 1

        attributes = @attempt.attributes.except('id')
        attributes['consumed_at'] = consumed_at
        attributes['encrypted_secrets'] = cleared
        attributes['created_at'] = @attempt.created_at
        attributes['updated_at'] = Time.current
        ExternalOauthAttempt.create!(attributes)
      end
    end
  end
end
