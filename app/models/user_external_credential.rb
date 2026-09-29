# frozen_string_literal: true

# == Schema Information
#
# Table name: user_external_credentials
#
#  id                :bigint(8)        not null, primary key
#  user_id           :bigint(8)        not null
#  provider          :string(64)       not null
#  purpose           :string(64)       not null
#  credential_type   :string(64)       not null
#  binding_id        :string(36)       not null
#  encrypted_payload :text             not null
#  encryption_key_id :string(32)       not null
#  display_name      :string(100)
#  expires_at        :datetime
#  revoked_at        :datetime
#  last_used_at      :datetime
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#

# Ciphertext record for a credential supplied by a user.
#
# This is encryption at rest plus application-level access checks. It is not
# end-to-end encryption. A server administrator who can read both this table
# and USER_EXTERNAL_CREDENTIAL_KEYS can decrypt the rows. There is no
# decrypted-secret reader on this model; UserCredentialVault is the only
# supported access path.
#
# Do not add a generic metadata JSON column. A future caller can mistake it
# for a place to store an API key. Add narrowly named non-secret columns when
# a consumer actually needs them.
class UserExternalCredential < ApplicationRecord
  IDENTIFIER_FORMAT = /\A[a-z][a-z0-9_]{0,63}\z/
  KEY_ID_FORMAT = /\A[a-z][a-z0-9_]{0,31}\z/
  BINDING_ID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  CIPHERTEXT_SEGMENT = /\A[A-Za-z0-9+\/]+={0,2}\z/
  CONTROL_CHARACTERS = /[\u0000-\u001F\u007F]/.freeze
  IMMUTABLE_FIELDS = %w(user_id provider purpose credential_type).freeze

  # Console inspection must not casually print ciphertext. The column reader
  # still returns ciphertext for the vault; do not send this model to a
  # browser or API serializer.
  self.filter_attributes += [:encrypted_payload]

  belongs_to :user, inverse_of: :external_credentials

  validates :provider, :purpose, :credential_type, :binding_id, :encrypted_payload, :encryption_key_id, presence: true
  validates :provider, :purpose, :credential_type, format: { with: IDENTIFIER_FORMAT }
  validates :encryption_key_id, format: { with: KEY_ID_FORMAT }
  validates :binding_id, format: { with: BINDING_ID_FORMAT }, uniqueness: true
  validates :display_name, length: { maximum: 100 }, allow_nil: true
  validate :display_name_is_plain_text
  validate :encrypted_payload_is_ciphertext
  validate :classification_is_immutable, on: :update
  validate :ciphertext_moves_with_binding_or_key, on: :update

  # as_json/to_json always drop ciphertext, including when `only:` asks for it.
  def serializable_hash(options = nil)
    hash = super
    hash.delete('encrypted_payload')
    hash.delete(:encrypted_payload)
    hash
  end

  private

  def display_name_is_plain_text
    return if display_name.nil?
    errors.add(:display_name, 'cannot contain control characters') if display_name.match?(CONTROL_CHARACTERS)
  end

  def encrypted_payload_is_ciphertext
    parts = encrypted_payload.to_s.split('--', -1)
    return if parts.length == 3 && parts.all? { |part| part.match?(CIPHERTEXT_SEGMENT) }

    errors.add(:encrypted_payload, 'must be ciphertext')
  end

  def classification_is_immutable
    IMMUTABLE_FIELDS.each do |name|
      errors.add(name, 'cannot be changed') if will_save_change_to_attribute?(name)
    end
  end

  def ciphertext_moves_with_binding_or_key
    payload_changed = will_save_change_to_attribute?('encrypted_payload')
    binding_changed = will_save_change_to_attribute?('binding_id')
    key_changed = will_save_change_to_attribute?('encryption_key_id')

    if (binding_changed || key_changed) && !payload_changed
      errors.add(:encrypted_payload, 'must be replaced when binding_id or encryption_key_id changes')
    end

    return unless payload_changed && !binding_changed && !key_changed

    errors.add(:encrypted_payload, 'cannot be replaced without a new binding_id or encryption_key_id')
  end
end
