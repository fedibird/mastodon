# frozen_string_literal: true

# Single-use OAuth attempt. PKCE and the session DPoP private key live only
# in encrypted_secrets. The row is bound to the user and browser that started it.
class ExternalOauthAttempt < ApplicationRecord
  self.filter_attributes += [:encrypted_secrets]

  belongs_to :user, inverse_of: :external_oauth_attempts

  validates :provider, :state_digest, :browser_binding_digest, :input_kind, :issuer,
            :authorization_endpoint, :token_endpoint, :par_endpoint, :redirect_uri,
            :requested_scopes, :binding_id, :encrypted_secrets, :encryption_key_id, :expires_at,
            presence: true
  validates :state_digest, uniqueness: true
  validates :binding_id, format: { with: UserExternalCredential::BINDING_ID_FORMAT }
  validates :encryption_key_id, format: { with: UserExternalCredential::KEY_ID_FORMAT }

  def serializable_hash(options = nil)
    hash = super
    hash.delete('encrypted_secrets')
    hash.delete(:encrypted_secrets)
    hash
  end
end
