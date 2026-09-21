# frozen_string_literal: true

# Authoritative claim/enqueue for one global Follow Import tick.
#
# A plan is not a reservation. Each entry is re-checked against current
# DB state: operational + scheduler-owned batch, recoverable Import/CSV
# work, then pending -> queued via TargetTransitionService. Only a
# successful pending->queued transition plus a successful
# RelationshipWorker enqueue counts as a claim.
#
# The planner is not the mutation boundary. A historical scheduler-owned
# row must not be claimed even if a stale plan or a direct executor call
# supplies an entry. Owner+cohort are re-checked inside the claim fence.
#
# skipped_wrong_owner_count is the GLOBAL claim-scope skip: the batch is
# not (operational AND scheduler-owned). A wrong cohort is counted here
# because it is the same fail-closed claim rejection, not a distinct
# owner-axis event.
#
# ImportUnitResolver is cached per batch_id so one CSV is not reparsed
# for every target from the same batch in this tick.
#
# pending -> queued is fenced: a short transaction locks the dispatcher
# lease row, verifies token + generation + DB-clock expiry, and applies
# mark_queued in that same transaction. CSV resolution stays outside.
# Enqueue happens after that claim commits. If a newer generation stole
# the lease, this generation cannot queue the target.
#
# On enqueue failure: release that target's queued claim, stop admitting
# further targets, keep already-enqueued claims, leave the rest pending.
# The scheduler job is retry: 0; the next periodic tick has a fresh budget.
module FollowImport
  class DispatchExecutor
    Result = Struct.new(
      :claimed_count,
      :skipped_stale_count,
      :skipped_unrecoverable_count,
      :skipped_wrong_owner_count,
      :error_class,
      :stopped,
      keyword_init: true
    ) do
      def error?
        error_class.present?
      end
    end

    def initialize(lease:, now: Time.now.utc)
      @now = now
      @lease = lease
      @resolvers = {}
      @transitions = FollowImport::TargetTransitionService.new
    end

    def execute(entries)
      result = Result.new(
        claimed_count: 0,
        skipped_stale_count: 0,
        skipped_unrecoverable_count: 0,
        skipped_wrong_owner_count: 0,
        error_class: nil,
        stopped: false
      )

      Array(entries).each do |entry|
        break if result.stopped

        claim_entry(entry, result)
      end

      result
    rescue StandardError => e
      result.error_class ||= e.class.name
      result.stopped = true
      result
    end

    private

    def claim_entry(entry, result)
      unless lease_owned?
        lost_ownership!(result)
        return
      end

      target = nil
      batch = FollowImportBatch.find_by(id: entry.batch_id)
      unless batch&.globally_claimable?
        result.skipped_wrong_owner_count += 1
        return
      end

      target = batch.targets.find_by(id: entry.target_id)
      if target.nil? || !target.state_pending?
        result.skipped_stale_count += 1
        return
      end

      account = batch.for_account
      work = work_for(batch, target)
      if account.nil? || work.nil?
        result.skipped_unrecoverable_count += 1
        return
      end

      outcome = fenced_mark_queued(target, batch)
      if outcome == :lost_ownership
        lost_ownership!(result)
        return
      end
      if outcome == :wrong_scope
        result.skipped_wrong_owner_count += 1
        return
      end
      if outcome == :stale
        result.skipped_stale_count += 1
        return
      end

      enqueue_follow(account, target, work, batch)
      result.claimed_count += 1
      release_csv_if_dispatched(batch)
    rescue StandardError => e
      release_failed_claim(target)
      result.error_class = e.class.name
      result.stopped = true
    end

    def lease_owned?
      !@lease.nil? && @lease.current_owner?
    end

    def fenced_mark_queued(target, batch)
      outcome = :lost_ownership
      fenced = FollowImport::DispatchLease.with_claim_fence(@lease) do
        batch.lock!
        unless batch.globally_claimable?
          outcome = :wrong_scope
        else
          @transitions.mark_queued(target, at: @now)
          outcome = if target.saved_change_to_state? && target.state_queued?
                      :queued
                    else
                      :stale
                    end
        end
      end
      return :lost_ownership unless fenced

      outcome
    end

    def lost_ownership!(result)
      result.stopped = true
      result.error_class ||= 'FollowImport::DispatchLease::LostOwnership'
    end

    def work_for(batch, target)
      resolver_for(batch).work_for(target)
    end

    def resolver_for(batch)
      @resolvers[batch.id] ||= FollowImport::ImportUnitResolver.new(Import.find_by(id: batch.import_id))
    end

    def enqueue_follow(account, target, work, batch)
      options = work[:options].merge(import_batch_id: batch.id, follow_import_target_id: target.id)
      Import::RelationshipWorker.perform_async(account.id, work[:acct], 'follow', options.stringify_keys)
    end

    def release_failed_claim(target)
      return if target.nil?

      @transitions.release_queued_claim(target)
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('dispatch_release_claim', e)
    end

    # Failure-tolerant and consistent with FollowImportCsvCleanupScheduler:
    # the CSV may be removed only when no pending targets remain.
    def release_csv_if_dispatched(batch)
      return if batch.targets.where(state: :pending).exists?

      Import.find_by(id: batch.import_id)&.destroy
    rescue StandardError => e
      Rails.logger.warn("[FollowImport::DispatchExecutor] failed to finalize import for batch #{batch.id}: #{e.class}: #{e.message}")
    end
  end
end
