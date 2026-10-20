# frozen_string_literal: true

# Connection metadata for one user-owned external identity.
#
# The DID in subject is the identity key. Handles are display data.
# credential_id points at ciphertext; this row does not store tokens.
class ExternalIdentity < ApplicationRecord
  STATUSES = %w(connected warning disconnected reauthentication_required).freeze
  TERMS = %w(unreviewed approved rejected).freeze

  belongs_to :user, inverse_of: :external_identities
  belongs_to :credential, class_name: 'UserExternalCredential', optional: true, inverse_of: false

  validates :provider, :subject, :issuer, :resource_origin, :token_endpoint, :status, :terms_state, presence: true
  validates :provider, format: { with: UserExternalCredential::IDENTIFIER_FORMAT }
  validates :status, inclusion: { in: STATUSES }
  validates :terms_state, inclusion: { in: TERMS }
  validates :subject, uniqueness: { scope: [:user_id, :provider] }
  validate :credential_belongs_to_owner
  validate :error_code_is_safe

  # The attempt and credential written by the callback that created this session.
  # Disconnect and refresh capture it before a network call and write a revocation
  # result only when both values are still current.
  def oauth_session_stamp
    [bound_attempt_id, credential_id]
  end

  private

  def credential_belongs_to_owner
    return if credential_id.nil?

    row = UserExternalCredential.find_by(id: credential_id)
    return errors.add(:credential, :invalid) if row.nil? || row.user_id != user_id

    expected = [
      ExternalBridge::Atproto::Codes::PROVIDER,
      ExternalBridge::Atproto::Codes::PURPOSE,
      ExternalBridge::Atproto::Codes::CREDENTIAL_TYPE,
    ]
    errors.add(:credential, :invalid) unless expected == [row.provider, row.purpose, row.credential_type]
  end

  def error_code_is_safe
    return if last_error_code.blank?
    return if ExternalBridge::Atproto::Codes::CODES.include?(last_error_code)

    errors.add(:last_error_code, :invalid)
  end
end
