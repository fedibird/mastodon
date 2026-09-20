# frozen_string_literal: true

# Single-flight lease for the global Follow Import dispatcher.
#
# Sidekiq `lock: :until_executed` only deduplicates jobs. Redis can lose that
# lock. The correctness boundary for "only one tick may hold the global
# scheduler critical section" is this PostgreSQL SESSION advisory lock.
#
# pg_try_advisory_lock / pg_advisory_unlock are session-level: they survive
# COMMIT and ROLLBACK and are released only by unlock on the same session or
# by disconnect. They are also REENTRANT on the same session: calling
# pg_try_advisory_lock again while already holding the same key returns true and
# increments the hold count. That matters for pooled connections: if a previous
# execution leaks one hold, a later tick on that same session must not treat the
# reentrant true as a fresh exclusive acquisition and then unlock only once.
#
# Therefore this class:
#
# - uses the thread-cached ActiveRecord connection (pool.with_connection)
#   so the tick's normal queries reuse the leased session
# - detects and clears a pre-existing hold of THIS lease key on the current
#   session before attempting a fresh acquisition
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
# A pre-existing hold on the current session is always stale for this class:
# DispatchScheduler never nests DispatchLease on the same thread/session. The
# stale hold is drained for this exact advisory key, then the tick performs a
# fresh pg_try_advisory_lock. If stale recovery or normal unlock cannot be
# confirmed, the connection is disconnected and removed from the pool so a
# still-locked session is never reused for unrelated application work.
module FollowImport
  class DispatchLease
    # Stable two-integer identity: ASCII 'FI' (0x4649) + object 1.
    # Documented constants — not Digest, not String#hash.
    LOCK_NAMESPACE = 0x4649
    LOCK_KEY       = 1

    # PostgreSQL represents two-int advisory locks in pg_locks with objsubid = 2.
    CURRENT_SESSION_LOCK_SQL = <<~SQL.squish
      SELECT EXISTS (
        SELECT 1
        FROM pg_locks
        WHERE locktype = 'advisory'
          AND classid = #{LOCK_NAMESPACE}
          AND objid = #{LOCK_KEY}
          AND objsubid = 2
          AND granted
          AND pid = pg_backend_pid()
      )
    SQL

    TRY_LOCK_SQL = "SELECT pg_try_advisory_lock(#{LOCK_NAMESPACE}, #{LOCK_KEY})"
    UNLOCK_SQL   = "SELECT pg_advisory_unlock(#{LOCK_NAMESPACE}, #{LOCK_KEY})"

    # Defensive bound only. A healthy execution has depth 0 before acquire and
    # depth 1 while held. Reaching this many stale holds means session state is
    # corrupt enough that disconnecting is safer than continuing to unwind.
    MAX_STALE_LOCK_DEPTH = 32

    BUSY = :busy

    def self.with_lease(&block)
      new.with_lease(&block)
    end

    # Yields only when a FRESH session lease is acquired.
    #
    # If the current pooled session already owns this lock before acquisition,
    # recover that stale ownership first. If another PostgreSQL session owns the
    # lock, pg_try_advisory_lock returns false and this method returns BUSY.
    #
    # When the lease is acquired, returns the block result. Always unlocks (or
    # isolates) in ensure, before the session is reusable.
    def with_lease
      pool = ActiveRecord::Base.connection_pool

      pool.with_connection do |connection|
        acquired = false
        begin
          return BUSY unless recover_stale_current_session_lease!(pool, connection)

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

    def current_session_holds_lock?(connection)
      boolean_result(connection.select_value(CURRENT_SESSION_LOCK_SQL))
    end

    def unlock_once?(connection)
      boolean_result(connection.select_value(UNLOCK_SQL))
    end

    # A current-session hold before our fresh acquire is stale by invariant.
    # Drain only THIS advisory key; never call pg_advisory_unlock_all().
    #
    # Returns true when the session is verified clear and can be reused for a
    # fresh acquisition. On any uncertainty, isolates/removes the connection and
    # returns false so the current tick does not enter the critical section.
    def recover_stale_current_session_lease!(pool, connection)
      return true unless current_session_holds_lock?(connection)

      Rails.logger.error('[FollowImport::DispatchLease] current DB session already owned dispatcher advisory lock before acquisition; recovering stale lease')

      released = 0

      while current_session_holds_lock?(connection)
        if released >= MAX_STALE_LOCK_DEPTH
          Rails.logger.error("[FollowImport::DispatchLease] stale advisory lock depth exceeded #{MAX_STALE_LOCK_DEPTH}; isolating connection")
          isolate_and_remove!(pool, connection)
          return false
        end

        unless unlock_once?(connection)
          Rails.logger.error('[FollowImport::DispatchLease] stale advisory unlock could not be confirmed; isolating connection')
          isolate_and_remove!(pool, connection)
          return false
        end

        released += 1
      end

      Rails.logger.warn("[FollowImport::DispatchLease] recovered #{released} stale advisory lock hold(s) on current DB session")
      true
    rescue StandardError => e
      Rails.logger.error("[FollowImport::DispatchLease] stale advisory lock recovery failed: #{e.class}: #{e.message}")
      isolate_and_remove!(pool, connection)
      false
    end

    def release_lease(pool, connection, acquired)
      return unless acquired
      return if unlock_once?(connection)

      Rails.logger.error('[FollowImport::DispatchLease] advisory unlock not confirmed after dispatcher tick; isolating connection')
      isolate_and_remove!(pool, connection)
    rescue StandardError => e
      Rails.logger.error("[FollowImport::DispatchLease] advisory unlock failed after dispatcher tick: #{e.class}: #{e.message}")
      isolate_and_remove!(pool, connection)
    end

    def isolate_and_remove!(pool, connection)
      isolate_locked_connection!(connection)
      pool.remove(connection) if pool.respond_to?(:remove)
    end

    def isolate_locked_connection!(connection)
      Rails.logger.error('[FollowImport::DispatchLease] disconnecting advisory-lock connection so it is not returned to the pool')
      connection.disconnect!
    rescue StandardError => e
      Rails.logger.error("[FollowImport::DispatchLease] failed to disconnect advisory-lock connection: #{e.class}: #{e.message}")
    end

    def boolean_result(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end
  end
end
