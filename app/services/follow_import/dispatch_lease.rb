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
# - checks out ONE ActiveRecord connection for the lease lifetime
# - acquires and releases the lock on that exact connection
# - keeps the connection checked out until unlock (or conservative isolate)
# - never uses pg_try_advisory_xact_lock / a tick-spanning transaction
# - never derives the lock key from Ruby String#hash (process-randomized)
#
# If explicit unlock cannot be confirmed on an otherwise live pooled
# connection, the connection is disconnected and removed from the pool so a
# still-locked session is not reused for unrelated application work.
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
    # yielding when pg_try_advisory_lock is false. Returns :acquired after a
    # successful body. Always unlocks (or isolates) in ensure.
    def with_lease
      pool = ActiveRecord::Base.connection_pool
      connection = pool.checkout
      acquired = false

      begin
        acquired = try_lock?(connection)
        return BUSY unless acquired

        yield
      ensure
        finalize(pool, connection, acquired)
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

    def finalize(pool, connection, acquired)
      isolated = false

      if acquired
        isolated = !unlock?(connection)
        isolate_locked_connection!(connection) if isolated
      end
    ensure
      return_connection(pool, connection, isolated: isolated)
    end

    def isolate_locked_connection!(connection)
      Rails.logger.error('[FollowImport::DispatchLease] unlock not confirmed; disconnecting leased connection so it is not returned to the pool still locked')
      connection.disconnect!
    rescue StandardError => e
      Rails.logger.error("[FollowImport::DispatchLease] failed to disconnect unconfirmed lease connection: #{e.class}: #{e.message}")
    end

    def return_connection(pool, connection, isolated:)
      if isolated && pool.respond_to?(:remove)
        pool.remove(connection)
      else
        pool.checkin(connection)
      end
    rescue StandardError => e
      Rails.logger.error("[FollowImport::DispatchLease] failed to return leased connection: #{e.class}: #{e.message}")
      begin
        connection.disconnect!
      rescue StandardError
        nil
      end
    end

    def boolean_result(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end
  end
end
