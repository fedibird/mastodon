# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Deletes expired attempts and consumed tombstones in bounded batches.
    # Selects ids only, then delete_all, so ciphertext is neither loaded nor logged.
    class AttemptCleanup
      BATCH = 200
      MAX_BATCHES = 5

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
        consumed = ExternalOauthAttempt.where.not(consumed_at: nil).order(:id).limit(limit).pluck(:id)
        return consumed if consumed.size >= limit

        consumed + ExternalOauthAttempt.where(consumed_at: nil).where('expires_at <= ?', now).order(:id).limit(limit - consumed.size).pluck(:id)
      end

      private_class_method :candidate_ids
    end
  end
end
