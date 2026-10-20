# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Per-user cap on PAR attempts. Counts rows only. It does not read
    # encrypted_secrets.
    class AttemptLimiter
      OUTSTANDING_LIMIT = 5
      WINDOW_LIMIT = 10

      def self.assert!(user)
        raise Error, :account_required if user.nil?

        outstanding = ExternalOauthAttempt.where(user_id: user.id, provider: Codes::PROVIDER, consumed_at: nil).where('expires_at > ?', Time.current).count
        raise Error, :attempt_rate_limited if outstanding >= OUTSTANDING_LIMIT

        recent = ExternalOauthAttempt.where(user_id: user.id, provider: Codes::PROVIDER).where('created_at > ?', Authorize::ATTEMPT_TTL.ago).count
        raise Error, :attempt_rate_limited if recent >= WINDOW_LIMIT
      end
    end
  end
end
