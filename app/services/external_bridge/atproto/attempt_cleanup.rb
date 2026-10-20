# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Deletes expired open attempts, and consumed tombstones only after the
    # rate-limit window and the in-flight callback grace have both elapsed.
    # Selects ids only, then delete_all, so ciphertext is neither loaded nor logged.
    class AttemptCleanup
      BATCH = 200
      MAX_BATCHES = 5
      # Callback#consume! commits consumed_at before the token exchange returns.
      # Keep that row until this grace has passed so a cleanup run cannot
      # delete an attempt the callback is still using.
      CALLBACK_GRACE = 2.minutes

      def self.call(now: Time.current)
        removed = 0
        MAX_BATCHES.times do
          ids = candidate_ids(now, BATCH)
          break if ids.empty?

          removed += ExternalOauthAttempt.where(id: ids).delete_all
          break if ids.size < BATCH
        end
        removed
      end

      def self.candidate_ids(now, limit)
        window_closed = now - Authorize::ATTEMPT_TTL
        grace_closed = now - CALLBACK_GRACE
        consumed = ExternalOauthAttempt.where.not(consumed_at: nil).where('created_at <= ? AND consumed_at <= ?', window_closed, grace_closed).order(:id).limit(limit).pluck(:id)
        return consumed if consumed.size >= limit

        consumed + ExternalOauthAttempt.where(consumed_at: nil).where('expires_at <= ?', now).order(:id).limit(limit - consumed.size).pluck(:id)
      end

      private_class_method :candidate_ids
    end
  end
end
