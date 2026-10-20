# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Starts PAR for the signed-in user. The returned URL is the metadata
    # authorization endpoint plus client_id and request_uri.
    class Authorize
      ATTEMPT_TTL = 10.minutes

      def self.call(user:, identifier:, browser_token:, dns: Dns.live)
        new(user, identifier, browser_token, dns).call
      end

      def initialize(user, identifier, browser_token, dns)
        @user = user
        @identifier = identifier
        @browser_token = browser_token.to_s
        @dns = dns
      end

      def call
        prepare!
        @signing = SigningKey.current
        raise Error, :signing_key_unavailable unless pinned_signing_key?
        discovered = Discovery.call(@identifier, dns: @dns)
        scopes = Scopes.choose(discovered.scopes_supported)
        verifier, challenge = Proofs.pkce
        dpop = Proofs.generate_dpop_key
        state = SecureRandom.urlsafe_base64(32)
        pushed = push!(discovered, scopes, state, challenge, dpop, nil)
        store!(discovered, scopes, state, verifier, dpop, pushed.fetch('nonce'))
        TokenClient.authorization_redirect(endpoint: discovered.authorization_endpoint, issuer: discovered.issuer, request_uri: request_uri!(pushed.fetch('json')))
      end

      private

      def prepare!
        raise Error, :account_required if @user.nil? || !@user.persisted?
        raise Error, :state_rejected if @browser_token.blank?

        Feature.require!(@user)
        raise Error, :signing_key_unavailable unless ClientDocument.configured?
        raise Error, :vault_unavailable unless UserCredentialVault.available?

        AttemptLimiter.assert!(@user)
      end

      def pinned_signing_key?
        @signing&.kid&.match?(ExternalOauthAttempt::CLIENT_KEY_ID_FORMAT)
      end

      def push!(discovered, scopes, state, challenge, dpop, nonce) # rubocop:disable Metrics/ParameterLists -- PAR fields stay explicit
        fields = {
          'client_id' => ClientDocument.client_id,
          'response_type' => 'code',
          'redirect_uri' => ClientDocument.redirect_uri,
          'state' => state,
          'scope' => scopes.join(' '),
          'code_challenge' => challenge,
          'code_challenge_method' => 'S256',
        }
        fields['login_hint'] = discovered.login_hint if discovered.login_hint.present?
        TokenClient.post!(
          url: discovered.par_endpoint,
          issuer: discovered.issuer,
          fields: fields,
          dpop_key: dpop,
          nonce: nonce,
          dns: @dns,
          timeout_code: :authorization_rejected,
          failure_code: :authorization_rejected,
          signing: @signing
        )
      end

      def request_uri!(document)
        value = document['request_uri'].to_s
        raise Error, :authorization_rejected if value.blank?

        value
      end

      def store!(discovered, scopes, state, verifier, dpop, nonce) # rubocop:disable Metrics/ParameterLists -- attempt secrets stay explicit
        binding_id = SecureRandom.uuid
        ciphertext, key_id = AttemptBox.encrypt(
          user_id: @user.id,
          binding_id: binding_id,
          secrets: { 'pkce_verifier' => verifier, 'dpop_private_key' => dpop.to_pem }
        )
        ExternalOauthAttempt.transaction do
          lock_owner!
          AttemptLimiter.assert!(@user)
          ExternalOauthAttempt.create!(
            user_id: @user.id,
            provider: Codes::PROVIDER,
            state_digest: Digest::SHA256.hexdigest(state),
            browser_binding_digest: Digest::SHA256.hexdigest(@browser_token),
            input_kind: discovered.input_kind,
            login_hint: discovered.login_hint,
            intended_subject: discovered.did,
            issuer: discovered.issuer,
            resource_origin: discovered.resource_origin,
            authorization_endpoint: discovered.authorization_endpoint,
            token_endpoint: discovered.token_endpoint,
            par_endpoint: discovered.par_endpoint,
            revocation_endpoint: discovered.revocation_endpoint,
            redirect_uri: ClientDocument.redirect_uri,
            requested_scopes: scopes.join(' '),
            dpop_nonce: nonce,
            binding_id: binding_id,
            encrypted_secrets: ciphertext,
            encryption_key_id: key_id,
            client_key_id: @signing.kid,
            expires_at: ATTEMPT_TTL.from_now
          )
        end
      end

      def lock_owner!
        User.lock.find(@user.id)
      rescue ActiveRecord::RecordNotFound
        raise Error, :account_required
      end
    end
  end
end
