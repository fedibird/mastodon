# frozen_string_literal: true

class TranslationService::PersonalDeepL < TranslationService
  # Personal DeepL for one owner. The adapter keeps the owner, the credential
  # record, and a non-secret cache scope. It does not keep the API key.
  #
  # Every translate and languages call decrypts through UserCredentialVault
  # and builds TranslationService::DeepL only inside that block. The client
  # and the key are dropped before the block returns. That is lifetime
  # minimization, not memory zeroization.
  #
  # In-flight requests: with_credential reloads and authorizes the current row,
  # then yields without holding a database lock across the DeepL HTTP call.
  # Revoke, delete, or replace that wins before the yield prevents the request
  # from starting. A DeepL request that has already started is not cancelled
  # by a later revoke, delete, or replace. Do not describe it as cancelled.
  #
  # Cache scope is snapshotted at initialize from user_id, credential_id,
  # binding_id, and provider. A replace! changes binding_id, so a later
  # resolution uses a new scope. A result that lands in the old scope after
  # a race stays there and is not written to the shared instance cache.
  # Encryption-key rotation does not change binding_id, so that scope stays.
  PROVIDER = 'deepl'
  PURPOSE = 'translation'
  CREDENTIAL_TYPE = 'api_key'

  class << self
    # :none, :one, or :many. :many is ambiguous and must not select a row.
    def availability(user)
      case usable_rows(user).size
      when 0 then :none
      when 1 then :one
      else :many
      end
    end

    # The only usable personal credential, or nil when the viewer has none.
    # Raises when more than one usable row exists.
    def resolve(user)
      rows = usable_rows(user)
      return if rows.empty?
      raise TranslationService::AmbiguousPersonalProvider if rows.size > 1

      new(user, rows.first)
    end

    # Selection predicate. Ownership, revocation, and expiry are checked
    # again inside UserCredentialVault.with_credential before use.
    def usable_rows(user)
      return [] unless user.is_a?(User) && user.persisted?

      UserExternalCredential.where(
        user_id: user.id,
        provider: PROVIDER,
        purpose: PURPOSE,
        credential_type: CREDENTIAL_TYPE,
        revoked_at: nil
      ).where('expires_at IS NULL OR expires_at > ?', Time.current).limit(2).to_a
    end
  end

  def initialize(owner, credential)
    super()

    raise ArgumentError, 'owner is required' unless owner.is_a?(User)
    raise ArgumentError, 'credential binding is required' if credential.binding_id.blank?

    @owner = owner
    @credential = credential
    @user_id = owner.id
    @credential_id = credential.id
    @binding_id = credential.binding_id.to_s
  end

  def private_content_allowed?
    false
  end

  def personal_result_cache_key(source, target, content_hash)
    "#{cache_scope}/#{source}/#{target}/#{content_hash}"
  end

  def personal_languages_cache_key
    "#{cache_scope}/languages"
  end

  def translate(texts, source_language, target_language)
    with_deepl { |deepl| deepl.translate(texts, source_language, target_language) }
  end

  def languages
    with_deepl(&:languages)
  end

  private

  def cache_scope
    "v4:personal_translations/#{PROVIDER}/user/#{@user_id}/credential/#{@credential_id}/binding/#{@binding_id}"
  end

  def with_deepl
    # Drop the client before the method returns. This is not memory zeroization.
    deepl = nil

    begin
      UserCredentialVault.with_credential(
        owner: @owner,
        credential: @credential,
        provider: PROVIDER,
        purpose: PURPOSE,
        credential_type: CREDENTIAL_TYPE
      ) do |payload|
        deepl = build_client(payload)
        result = yield deepl
        deepl = nil
        result
      end
    rescue UserCredentialVault::Error, KeyError
      raise UnexpectedResponseError
    ensure
      deepl = nil
    end
  end

  # The DeepL client holds the key only for this synchronous call. The local
  # is cleared before the client is returned to the vault block.
  def build_client(payload)
    # rubocop:disable Lint/UselessAssignment -- drop the key local; this is not memory zeroization
    api_key = nil

    begin
      api_key = api_key_from(payload)
      client = TranslationService::DeepL.new(plan_for(api_key), api_key)
      api_key = nil
      client
    ensure
      api_key = nil
    end
    # rubocop:enable Lint/UselessAssignment
  end

  def api_key_from(payload)
    key = payload.fetch('credentials').fetch('api_key')
    raise KeyError, 'api_key is missing' unless key.is_a?(String) && !key.empty?

    key
  end

  # Official DeepL auth: a key ending in ":fx" is the Free API.
  # Instance DEEPL_PLAN is not consulted.
  def plan_for(api_key)
    api_key.end_with?(':fx') ? 'free' : 'pro'
  end
end
