# frozen_string_literal: true

# Single-flight lease for the global Follow Import dispatcher.
#
# Sidekiq `lock: :until_executed` only deduplicates jobs. Redis can lose that
# lock. The correctness boundary for "only one tick may hold the global
# scheduler critical section" is this PostgreSQL SESSION advisory lock.
#
# pg_try_advisory_lock / pg_advisory_unlock are session-level: they survive
# COMMIT and ROLLBACK and are released only by unlock on the same session or
# by disconnect. Therefore this class:
#
# - uses the thread-cached ActiveRecord connection (pool.with_connection)
#   so the tick's normal queries reuse the leased session
# - acquires and releases the lock on that exact connection
# - never uses pg_try_advisory_xact_lock / a tick-spanning transaction
# - never derives the lock key from Ruby String#hash (process-randomized)
#
# A tick therefore consumes ONE DB connection, not a dedicated lease
# connection plus a second one for ActiveRecord work. That matters under
# Fedibird's default Sidekiq concurrency 5 / DB pool 5: a manual
# pool.checkout that is not installed in the thread cache can take the
# last pool slot and then block while the global advisory lock is held.
#
# If explicit unlock cannot be confirmed on an otherwise live pooled
# connection, the connection is disconnected and pool.remove'd (Rails 6.1
# remove also clears the thread cache) so a still-locked session is not
# reused for unrelated application work.
module FollowImport
  class DispatchLease
    # Stable two-integer identity: ASCII 'FI' (0x4649) + object 1.
    # Documented constants — not Digest, not String#hash.
    LOCK_NAMESPACE = 0x4649
    LOCK_KEY       = 1

    TRY_LOCK_SQL = "SELECT pg_try_advisory_lock(#{LOCK_NAMESPACE}, #{LOCK_KEY})"
    UNLOCK_SQL   = "SELECT pg_advisory_unlock(#{LOCK_NAMESPACE}, #{LOCK_KEY})"

    BUSY = :busy

    def self.with_lease(&block)
      new.with_lease(&block)
    end

    # Yields only when the session lease is acquired. Returns :busy without
    # yielding when pg_try_advisory_lock is false. When the lease is
    # acquired, returns the block result. Always unlocks (or isolates) in
    # ensure, before the session is reusable.
    def with_lease
      pool = ActiveRecord::Base.connection_pool

      pool.with_connection do |connection|
        acquired = false
        begin
          acquired = try_lock?(connection)
          return BUSY unless acquired

          yield
        ensure
          release_lease(pool, connection, acquired)
        end
      end
    end

    private

    def try_lock?(connection)
      boolean_result(connection.select_value(TRY_LOCK_SQL))
    end

    def unlock?(connection)
      boolean_result(connection.select_value(UNLOCK_SQL))
    rescue StandardError => e
      Rails.logger.error("[FollowImport::DispatchLease] advisory unlock failed: #{e.class}: #{e.message}")
      false
    end

    def release_lease(pool, connection, acquired)
      return unless acquired
      return if unlock?(connection)

      isolate_locked_connection!(connection)
      pool.remove(connection) if pool.respond_to?(:remove)
    end

    def isolate_locked_connection!(connection)
      Rails.logger.error('[FollowImport::DispatchLease] unlock not confirmed; disconnecting leased connection so it is not returned to the pool still locked')
      connection.disconnect!
    rescue StandardError => e
      Rails.logger.error("[FollowImport::DispatchLease] failed to disconnect unconfirmed lease connection: #{e.class}: #{e.message}")
    end

    def boolean_result(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end
  end
end
