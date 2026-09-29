# frozen_string_literal: true

# HTML settings mutations for one personal DeepL API key.
#
# Classification is fixed in this class. Callers must not accept provider,
# purpose, credential_type, or an endpoint from the browser. The only secret
# argument is the API key string.
#
# Save and delete do not call DeepL and do not purge translation caches.
# A replacement binding_id makes the previous personal cache scope unreachable.
class DeepLCredentialSettings
  class Error < StandardError; end
  class InvalidKey < Error; end
  class Ambiguous < Error; end
  class Unavailable < Error; end

  MAX_API_KEY_LENGTH = 512
  PROVIDER = 'deepl'
  PURPOSE = 'translation'
  CREDENTIAL_TYPE = 'api_key'
  DISPLAY_NAME = 'DeepL'

  def self.scope_for(user)
    user.external_credentials.where(
      provider: PROVIDER,
      purpose: PURPOSE,
      credential_type: CREDENTIAL_TYPE
    )
  end

  def initialize(user)
    @user = user
  end

  def save!(raw_key)
    key = normalize!(raw_key)
    raise Unavailable unless UserCredentialVault.available?

    @user.with_lock do
      persist!(key, self.class.scope_for(@user).lock.order(:id).to_a)
    end
  end

  def delete!(id)
    @user.with_lock do
      credential = self.class.scope_for(@user).lock.find(id)
      UserCredentialVault.delete!(owner: @user, credential: credential)
    end
  end

  private

  def persist!(key, rows)
    case rows.size
    when 0
      store!(key)
    when 1
      replace!(rows.first, key)
    else
      raise Ambiguous
    end
  end

  def store!(key)
    UserCredentialVault.store!(
      owner: @user,
      provider: PROVIDER,
      purpose: PURPOSE,
      credential_type: CREDENTIAL_TYPE,
      credentials: { api_key: key },
      display_name: DISPLAY_NAME
    )
  end

  def replace!(credential, key)
    UserCredentialVault.replace!(
      owner: @user,
      credential: credential,
      provider: PROVIDER,
      purpose: PURPOSE,
      credential_type: CREDENTIAL_TYPE,
      credentials: { api_key: key },
      revoked_at: nil,
      expires_at: nil
    )
  end

  def normalize!(raw_key)
    raise InvalidKey unless raw_key.is_a?(String)

    key = raw_key.strip
    raise InvalidKey if key.blank?
    raise InvalidKey if key.match?(UserExternalCredential::CONTROL_CHARACTERS)
    raise InvalidKey if key.bytesize > MAX_API_KEY_LENGTH

    key
  end
end
