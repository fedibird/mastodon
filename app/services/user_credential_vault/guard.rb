# frozen_string_literal: true

module UserCredentialVault
  # Access checks that run before any decryption. A mismatch does not yield
  # and does not update last_used_at.
  module Guard
    module_function

    def credential!(credential)
      return if credential.is_a?(UserExternalCredential) && credential.persisted?

      raise ArgumentError, 'credential is required'
    end

    def owner!(owner, credential)
      owner_id = owner.is_a?(User) ? owner.id : nil
      return if owner_id.present? && owner_id == credential.user_id

      raise OwnerMismatch, 'credential owner mismatch'
    end

    def classification!(credential, provider:, purpose:, credential_type:)
      raise ProviderMismatch, 'credential provider mismatch' unless credential.provider == provider
      raise PurposeMismatch, 'credential purpose mismatch' unless credential.purpose == purpose
      raise CredentialTypeMismatch, 'credential type mismatch' unless credential.credential_type == credential_type
    end

    def usable!(credential, now: Time.current)
      raise Revoked, 'credential is revoked' if credential.revoked_at.present?
      raise Expired, 'credential is expired' if credential.expires_at.present? && credential.expires_at <= now
    end
  end
end
