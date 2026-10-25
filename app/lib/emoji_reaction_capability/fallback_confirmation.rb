# frozen_string_literal: true

module EmojiReactionCapability
  # Signed, short-lived consent for one Like-fallback or unknown write.
  #
  # The token is a Rails parameter, `fallback_confirmation`, from the JSON or
  # form body or the query string. A header is not accepted. The body is the
  # one to use: a query string is often stored by a proxy. The value is on
  # the filter_parameters list so the Rails log redacts it. Nothing here logs
  # the token or the jti.
  #
  # Purpose is emoji_reaction_fallback. The payload binds the reactor, the
  # canonical status id, the unicode string or the resolved custom emoji id,
  # the target domain, the mechanism, the activity that will be sent, and a
  # digest of the normalized node snapshot and the policy. Redemption
  # recomputes that binding and does not trust the token's claims on their own.
  module FallbackConfirmation
    EXPIRES_IN = 5.minutes
    PURPOSE = :emoji_reaction_fallback
    REDIS_TTL = EXPIRES_IN.to_i + 60
    MAX_TOKEN_BYTES = 4_000
    JTI_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    module JSONSerializer
      module_function

      def dump(value)
        JSON.generate(value)
      end

      def load(value)
        JSON.parse(value)
      end
    end

    module_function

    def expires_in
      EXPIRES_IN.to_i
    end

    def issue(payload)
      verifier.generate(payload, expires_in: EXPIRES_IN, purpose: PURPOSE)
    end

    def read(token)
      return unless token.is_a?(String)
      return if token.blank? || token.bytesize > MAX_TOKEN_BYTES

      body = verifier.verified(token, purpose: PURPOSE)
      body if body.is_a?(Hash)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError, TypeError, JSON::ParserError
      nil
    end

    # :ok the first time, :replay after that. Redis errors raise and do not
    # report success. The key outlives the token so a late replay cannot
    # succeed after the key expires but before the signature does.
    def consume!(jti)
      raise ArgumentError, 'jti' unless jti.is_a?(String) && jti.match?(JTI_FORMAT)

      stored = RedisConfiguration.with do |redis|
        redis.set(redis_key(jti), '1', nx: true, ex: REDIS_TTL)
      end
      [true, 'OK'].include?(stored) ? :ok : :replay
    rescue Redis::BaseError => e
      Rails.logger.warn("[emoji_reaction_fallback_policy] confirmation store unavailable: #{e.class}")
      raise Mastodon::EmojiReactionPolicyError.confirmation_unavailable
    end

    def verifier
      ActiveSupport::MessageVerifier.new(
        Rails.application.secret_key_base,
        digest: 'SHA256',
        serializer: JSONSerializer
      )
    end

    def redis_key(jti)
      "emoji_reaction_fallback:v1:#{jti}"
    end
  end
end
