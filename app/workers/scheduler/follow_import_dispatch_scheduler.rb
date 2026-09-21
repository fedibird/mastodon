# frozen_string_literal: true

# Periodic wrapper for FollowImport::DispatchScheduler.
#
# Named Scheduler::* to match existing Mastodon/Fedibird scheduler
# registration (config/sidekiq.yml queue: scheduler). The tick itself
# lives in FollowImport::DispatchScheduler.
#
# sidekiq_options:
# - retry: 0 — a raised tick must not replay. There is no stored budget;
#   the next cron/interval starts a fresh observation.
# - lock: :until_executed — Sidekiq/Redis job deduplication only. It is
#   NOT the correctness boundary for the global scheduler. Two jobs may
#   start if Redis loses the unique lock; only one may hold
#   FollowImport::DispatchLease (durable PostgreSQL row + fencing
#   generation; PgBouncer transaction-pooler safe).
#
# Cadence is FollowImport::ExecutionPolicy.dispatch_every
# (same ENV/default as config/sidekiq.yml). Provisional / UNCALIBRATED.
# It is not FOLLOW_IMPORT_EXECUTION_INTERVAL. When GLOBAL is on this
# interval is real admission pacing (no catch-up budget). The worker
# is a cheap no-op unless dispatch_global_enabled? or
# dispatch_shadow_enabled?.
class Scheduler::FollowImportDispatchScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0, lock: :until_executed

  def perform
    result = FollowImport::DispatchScheduler.new.call
    return result if result.outcome == FollowImport::DispatchScheduler::OUTCOME_SHADOW_DISABLED

    Rails.logger.info("[Scheduler::FollowImportDispatchScheduler] outcome=#{result.outcome} lease_acquired=#{result.lease_acquired} tick_id=#{result.tick_id}")
    result
  end
end
