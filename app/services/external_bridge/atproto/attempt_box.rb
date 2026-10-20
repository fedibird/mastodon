# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Encrypts PKCE and the session DPoP key for one OAuth attempt.
    # The ciphertext is not a user_external_credentials row.
    class AttemptBox
      PREFIX = 'external_oauth_attempt:v1'

      def self.encrypt(user_id:, binding_id:, secrets:)
        new.encrypt(user_id: user_id, binding_id: binding_id, secrets: secrets)
      end

      def self.decrypt(attempt)
        new.decrypt(attempt)
      end

      def self.tombstone(attempt)
        new.tombstone(attempt)
      end

      def encrypt(user_id:, binding_id:, secrets:)
        keyring = keyring!
        ciphertext = UserCredentialVault::Cipher.encrypt(secrets, key: keyring.primary_key, purpose: purpose(user_id, binding_id))
        [ciphertext, keyring.primary_id]
      end

      def decrypt(attempt)
        keyring = keyring!
        key = keyring.key_for!(attempt.encryption_key_id)
        UserCredentialVault::Cipher.decrypt(attempt.encrypted_secrets, key: key, purpose: purpose(attempt.user_id, attempt.binding_id))
      rescue UserCredentialVault::Error
        raise Error, :vault_unavailable
      end

      def tombstone(attempt)
        encrypt(user_id: attempt.user_id, binding_id: attempt.binding_id, secrets: { 'cleared' => '1' }).first
      end

      private

      def keyring!
        UserCredentialVault::Keyring.load!
      rescue UserCredentialVault::ConfigurationError
        raise Error, :vault_unavailable
      end

      def purpose(user_id, binding_id)
        "#{PREFIX}\x1e#{user_id}\x1e#{binding_id}"
      end
    end
  end
end
