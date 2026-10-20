# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Exchanges one authorization code after the browser, state, issuer, and
    # DID checks. A failed check stores neither an identity nor a credential.
    class Callback
      def self.call(user:, browser_token:, state:, iss:, code:, provider_error:, dns: Dns.live) # rubocop:disable Metrics/ParameterLists -- callback inputs stay named
        new(user, browser_token, state, iss, code, provider_error, dns).call
      end

      def initialize(user, browser_token, state, iss, code, provider_error, dns) # rubocop:disable Metrics/ParameterLists -- callback inputs stay named
        @user = user
        @browser_token = browser_token.to_s
        @state = state.to_s
        @iss = iss.to_s
        @code = code.to_s
        @provider_error = provider_error.to_s
        @dns = dns
      end

      def call
        raise Error, :account_required if @user.nil?
        raise Error, :authorization_rejected if @provider_error.present?

        attempt, secrets = consume!
        Feature.require!(@user)
        raise Error, :issuer_mismatch unless Origin.https_origin!(@iss) == attempt.issuer
        raise Error, :authorization_rejected if @code.blank? || @code.bytesize > 2048

        exchanged = exchange!(attempt, secrets)
        commit!(attempt, secrets, exchanged)
      end

      private

      def consume!
        raise Error, :state_rejected if @state.blank? || @browser_token.blank?

        secrets = nil
        attempt = ExternalOauthAttempt.transaction do
          row = ExternalOauthAttempt.lock.find_by(state_digest: Digest::SHA256.hexdigest(@state), provider: Codes::PROVIDER)
          reject_attempt!(row)
          @signing = SigningKey.for_kid(row.client_key_id)
          raise Error, :signing_key_unavailable if @signing.nil?

          secrets = read_secrets(row)
          row.update!(consumed_at: Time.current, encrypted_secrets: AttemptBox.tombstone(row))
          row
        end
        raise Error, :vault_unavailable if secrets.nil?

        [attempt, secrets]
      end

      def reject_attempt!(row)
        raise Error, :state_rejected if row.nil? || row.consumed_at.present? || row.expires_at <= Time.current || row.user_id != @user.id

        actual = Digest::SHA256.hexdigest(@browser_token)
        expected = row.browser_binding_digest.to_s
        raise Error, :state_rejected unless expected.bytesize == actual.bytesize && ActiveSupport::SecurityUtils.secure_compare(expected, actual)
      end

      def read_secrets(row)
        AttemptBox.decrypt(row)
      rescue Error
        nil
      end

      def exchange!(attempt, secrets)
        raise Error, :signing_key_unavailable if @signing.nil?

        dpop = OpenSSL::PKey::EC.new(secrets.fetch('dpop_private_key'))
        TokenClient.post!(
          url: attempt.token_endpoint,
          issuer: attempt.issuer,
          fields: token_fields(attempt, secrets),
          dpop_key: dpop,
          nonce: attempt.dpop_nonce,
          dns: @dns,
          timeout_code: :authorization_rejected,
          failure_code: :authorization_rejected,
          signing: @signing
        )
      end

      def token_fields(attempt, secrets)
        {
          'grant_type' => 'authorization_code',
          'code' => @code,
          'redirect_uri' => attempt.redirect_uri,
          'client_id' => ClientDocument.client_id,
          'code_verifier' => secrets.fetch('pkce_verifier'),
        }
      end

      def commit!(attempt, secrets, exchanged)
        tokens = token_document(exchanged.fetch('json'))
        subject = tokens.fetch('sub')
        raise Error, :authorization_rejected if attempt.intended_subject.present? && attempt.intended_subject != subject

        granted, partial = Scopes.accept!(attempt.requested_scopes.split(' '), tokens['scope'])
        confirmed = Discovery.confirm!(did: subject, issuer: attempt.issuer, dns: @dns)
        SessionStore.save!(
          user: @user,
          attempt: attempt,
          subject: subject,
          handle: confirmed[:handle],
          resource_origin: confirmed.fetch(:resource_origin),
          granted_scopes: granted,
          partial: partial,
          secrets: vault_secrets(attempt, secrets, exchanged, tokens, granted)
        )
      rescue Error
        discard!(attempt, secrets, exchanged)
        raise
      end

      def token_document(json)
        raise Error, :authorization_rejected unless json['token_type'].to_s.casecmp('dpop').zero?
        raise Error, :authorization_rejected unless Did.valid?(json['sub'].to_s)
        raise Error, :authorization_rejected unless json['expires_in'].to_i.positive?

        json
      end

      def vault_secrets(attempt, secrets, exchanged, tokens, granted)
        expires_in = [tokens['expires_in'].to_i, 30.minutes.to_i].min
        SessionStore.credentials(
          tokens: tokens,
          pem: secrets.fetch('dpop_private_key'),
          nonce: exchanged.fetch('nonce'),
          endpoint: attempt.token_endpoint,
          issuer: attempt.issuer,
          kid: bound_kid,
          scopes: granted,
          generation: 0,
          expires_at: expires_in.seconds.from_now
        )
      end

      def bound_kid
        raise Error, :signing_key_unavailable if @signing.nil?

        @signing.kid
      end

      def discard!(attempt, secrets, exchanged)
        return if exchanged.nil? || @signing.nil?

        refresh = exchanged.fetch('json')['refresh_token'].to_s
        return if refresh.blank? || attempt.revocation_endpoint.blank?

        dpop = OpenSSL::PKey::EC.new(secrets.fetch('dpop_private_key'))
        TokenClient.post!(
          url: attempt.revocation_endpoint,
          issuer: attempt.issuer,
          fields: { 'token' => refresh, 'token_type_hint' => 'refresh_token', 'client_id' => ClientDocument.client_id },
          dpop_key: dpop,
          nonce: exchanged.fetch('nonce'),
          dns: @dns,
          timeout_code: :authorization_rejected,
          failure_code: :authorization_rejected,
          signing: @signing
        )
      rescue Error, OpenSSL::PKey::PKeyError
        nil
      end
    end
  end
end
