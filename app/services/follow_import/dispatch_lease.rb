# frozen_string_literal: true

# Single-flight lease for the global Follow Import dispatcher.
#
# Sidekiq `lock: :until_executed` only deduplicates jobs. Redis can lose that
# lock. Target row locks prevent duplicate work for one target but do not
# enforce one global admission budget.
#
# The correctness boundary is a durable singleton PostgreSQL row plus a
# monotonic fencing generation. Acquisition/release serialization uses a
# short `pg_try_advisory_xact_lock` transaction, which is compatible with
# PgBouncer transaction pooling because the pooler pins a server backend for
# an explicit transaction. The scheduler body then runs on ordinary
# connections. Session-level advisory locks are never used: they leak across
# autocommit statements when the client is a transaction pooler.
#
# Crash recovery is the row's `expires_at`, compared with PostgreSQL
# `clock_timestamp()`. The liveness window is the existing dispatcher
# cadence (`ExecutionPolicy.dispatch_interval`), not a new pacing budget.
# The durable row may expire while snapshot/planning/telemetry still
# run; that is not a claim. Authoritative `pending -> queued` runs
# inside a short transaction that locks this singleton row and checks
# token + generation + DB-clock expiry, so a stolen/expired generation
# cannot mark a target queued. Already-enqueued claims are not rolled
# back.
module FollowImport
  class DispatchLease
    STRATEGY = 'durable_row_v1'

    # Stable two-integer identity: ASCII 'FI' (0x4649) + object 1.
    # Used only as a short transaction-scoped serialization primitive.
    LOCK_NAMESPACE = 0x4649
    LOCK_KEY       = 1

    TRY_XACT_LOCK_SQL = "SELECT pg_try_advisory_xact_lock(#{LOCK_NAMESPACE}, #{LOCK_KEY})"

    BUSY = :busy

    Handle = Struct.new(:owner_token, :fencing_generation, :strategy, keyword_init: true) do
      def current_owner?
        FollowImport::DispatchLease.owned?(self)
      end
    end

    def self.with_lease(&block)
      new.with_lease(&block)
    end

    def self.owned?(handle)
      new.owned?(handle)
    end

    def self.with_claim_fence(handle, &block)
      new.with_claim_fence(handle, &block)
    end

    # Yields a Handle only when a fresh durable lease is acquired.
    # Returns BUSY when another unexpired owner exists, when acquisition
    # cannot be serialized, or when setup fails. Fail closed: never yield
    # unleased.
    def with_lease
      handle = nil
      handle = acquire
      return BUSY if handle.nil?

      yield handle
    ensure
      release(handle) if handle
    end

    def owned?(handle)
      return false if handle.nil? || handle.owner_token.blank?

      FollowImportDispatchLease
        .where(
          id: FollowImportDispatchLease::SINGLETON_ID,
          owner_token: handle.owner_token,
          fencing_generation: handle.fencing_generation
        )
        .where('expires_at > clock_timestamp()')
        .exists?
    end

    # Short mutation fence: lock the singleton row, verify this handle
    # still owns it, then run the block in the same transaction.
    # Acquire/steal also lock this row, so takeover and pending->queued
    # are ordered. Returns false without yielding when ownership is lost.
    # The block must stay cheap (row-locked claim only), not CSV parse.
    def with_claim_fence(handle)
      return false if handle.nil? || handle.owner_token.blank?

      applied = false
      ApplicationRecord.transaction do
        row = FollowImportDispatchLease.lock.find_by(id: FollowImportDispatchLease::SINGLETON_ID)
        raise ActiveRecord::Rollback unless current_row?(row, handle)

        yield
        applied = true
      end
      applied
    end

    private

    def acquire
      handle = nil

      ApplicationRecord.transaction do
        raise ActiveRecord::Rollback unless try_xact_lock?

        row = FollowImportDispatchLease.lock.find_by(id: FollowImportDispatchLease::SINGLETON_ID)
        raise ActiveRecord::Rollback if row.nil?

        now = database_time
        raise ActiveRecord::Rollback if row.held_at?(now)

        token = SecureRandom.uuid
        generation = row.fencing_generation.to_i + 1
        row.update!(
          owner_token: token,
          fencing_generation: generation,
          expires_at: now + ttl
        )
        handle = Handle.new(owner_token: token, fencing_generation: generation, strategy: STRATEGY)
      end

      handle
    rescue ActiveRecord::Rollback
      nil
    rescue StandardError => e
      Rails.logger.error("[FollowImport::DispatchLease] acquisition failed: #{e.class}: #{e.message}")
      nil
    end

    def release(handle)
      FollowImportDispatchLease.where(
        id: FollowImportDispatchLease::SINGLETON_ID,
        owner_token: handle.owner_token,
        fencing_generation: handle.fencing_generation
      ).update_all(
        owner_token: nil,
        expires_at: nil,
        updated_at: Time.now.utc
      )
    rescue StandardError => e
      Rails.logger.error("[FollowImport::DispatchLease] release failed: #{e.class}: #{e.message}")
    end

    def current_row?(row, handle)
      return false if row.nil?
      return false unless row.owner_token == handle.owner_token
      return false unless row.fencing_generation.to_i == handle.fencing_generation.to_i

      now = database_time
      now.present? && row.held_at?(now)
    end

    def try_xact_lock?
      boolean_result(connection.select_value(TRY_XACT_LOCK_SQL))
    end

    def database_time
      value = connection.select_value('SELECT clock_timestamp()')
      time = value.is_a?(Time) ? value : Time.zone.parse(value.to_s)
      time&.utc
    end

    def ttl
      FollowImport::ExecutionPolicy.dispatch_interval
    end

    def boolean_result(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end

    def connection
      ApplicationRecord.connection
    end
  end
end
