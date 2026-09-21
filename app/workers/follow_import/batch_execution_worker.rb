# frozen_string_literal: true

# Controlled, DB-backed execution of a follow-import batch.
#
# Instead of firing every follow at once, each pass CLAIMS at most a small fixed
# number of still-pending targets (in position order, via the row-locked,
# idempotent transition service), transitions the ones it will execute to
# `queued`, and enqueues their relationship work. The database target set — not
# the CSV and not the Sidekiq queue — is the unit of work and the source of
# truth; the CSV is consulted only to recover each claimed target's address and
# follow options (which are not persisted), never to slice work into chunks.
#
# The adaptive follow gate is evaluated and logged every pass for observation,
# but is SHADOW BY DEFAULT: it only changes execution when the experimental
# FollowImport::ExecutionPolicy.gate_enforcement_enabled? flag is on.
#
# This worker owns ONLY ready, legacy-dispatch batches. A scheduler-owned
# or non-ready batch is refused immediately after find — before
# LoadSnapshot, load enforcement, candidate selection, the gate,
# resolver, claims, enqueue, reschedule, or Import cleanup.
#
# When FOLLOW_IMPORT_LOCAL_LOAD_ENFORCEMENT is on and an enforcement-capable
# local-load profile is configured, LocalLoadGuard may shrink this pass's
# candidate LIMIT from the pre-dispatch LoadSnapshot, or defer the entire
# pass (claim nothing, retain the Import, schedule one batch-level recheck).
# That is per-pass protection, not a global claim budget. Gate / unrecoverable
# zero progress still does not automatically reschedule.
#
# Rescheduling is gated on FORWARD PROGRESS except for an explicit local-load
# deferral: the next pass is only enqueued when at least one target was
# claimed+executed this pass, or when the pass was skipped because local load
# produced a zero budget while pending work remains.
module FollowImport
  class BatchExecutionWorker
    include Sidekiq::Worker

    sidekiq_options queue: 'pull', retry: 5

    def perform(batch_id)
      batch = FollowImportBatch.find_by(id: batch_id)
      return if batch.nil?
      # Defense in depth: a scheduler-owned batch has exactly one owner.
      # A non-ready batch is not executable. A stale/duplicate
      # BatchExecutionWorker must not snapshot, claim, enqueue,
      # reschedule, or finalize. Do not treat non-ready as completed.
      return if batch.scheduler_dispatch_owner?
      return unless batch.ready_preflight_state?

      account    = batch.subject&.account
      now        = Time.now.utc
      snapshot   = capture_pre_dispatch_snapshot(batch, now)

      # candidate_count stays nil until the pending-target query succeeds so an
      # interrupted/failed selection is not recorded as an observed 0.
      # A load-deferred pass intentionally does not run that query, so it
      # keeps NULL and records effective_execution_budget=0 / load_deferred.
      # claimed_count is incremented after each successful enqueue so a later
      # raise still reports how far the pass got.
      @dispatch_candidate_count = account ? nil : 0
      @dispatch_claimed_count   = 0
      @dispatch_pass_error      = nil
      @dispatch_load_deferred   = false
      @local_load               = nil

      begin
        @local_load = FollowImport::LocalLoadEnforcement.evaluate(
          load_snapshot: snapshot[:load_snapshot],
          base_budget: FollowImport::ExecutionPolicy.execution_batch_size
        )

        if account
          if @local_load.skip_selection?
            @dispatch_load_deferred = true
            log_local_load_enforcement(batch)
          else
            candidates = select_pending_candidates(batch, limit: @local_load.effective_budget)
            @dispatch_candidate_count = candidates.size
            execute_pass(batch, account, candidates, now) unless candidates.empty?
            log_local_load_enforcement(batch) if noteworthy_local_load_enforcement?
          end
        end

        if account && batch.targets.where(state: :pending).exists?
          # Load deferral is tracked explicitly — do not infer it from
          # claimed_count == 0 (that also happens for gate / unrecoverable).
          reschedule(batch) if @dispatch_load_deferred || @dispatch_claimed_count.positive?
        else
          @dispatch_load_deferred = false
          # No pending targets remain (dispatch complete, or nothing to do, or the
          # importer is gone). Every follow has been enqueued with its address in the
          # job args, so the uploaded CSV is no longer needed — destroy the import.
          finalize_import!(batch)
        end
      rescue StandardError => e
        @dispatch_pass_error = e.class.name
        raise
      ensure
        record_dispatch_observation(batch, snapshot)
      end
    end

    private

    def select_pending_candidates(batch, limit:)
      batch.targets.where(state: :pending).order(:position).limit(limit).to_a
    end

    def execute_pass(batch, account, candidates, now)
      gate = FollowImport::ExecutionGate.for_account(account, now: now)
      Rails.logger.info("[FollowImport::BatchExecutionWorker] #{observation(batch, candidates.size, gate).to_json}")

      return unless gate.execute?

      resolver    = FollowImport::ImportUnitResolver.new(import_for(batch))
      transitions = FollowImport::TargetTransitionService.new

      candidates.each do |target|
        work = resolver.work_for(target)
        next if work.nil? # address/options unrecoverable (rare) — leave pending

        transitions.mark_queued(target, at: now)
        # Only this pass's successful claim (pending -> queued) counts and
        # enqueues; a concurrent pass that already claimed it is a no-op here.
        next unless target.saved_change_to_state? && target.state_queued?

        begin
          enqueue_follow(account, target, work, batch)
        rescue StandardError
          # The claim (queued) is persisted but its work was NOT enqueued. Release
          # the claim (queued -> pending) so a retry can reselect it — otherwise it
          # would be stranded (only pending targets are claimable) — and re-raise
          # so Sidekiq retries this pass.
          transitions.release_queued_claim(target)
          raise
        end

        @dispatch_claimed_count += 1
      end
    end

    def enqueue_follow(account, target, work, batch)
      options = work[:options].merge(import_batch_id: batch.id, follow_import_target_id: target.id)
      Import::RelationshipWorker.perform_async(account.id, work[:acct], 'follow', options.stringify_keys)
    end

    def reschedule(batch)
      self.class.perform_in(FollowImport::ExecutionPolicy.execution_reschedule_in, batch.id)
    end

    # Destroy the uploaded import once its follows are dispatched. The batch (and
    # its target rows) persist as the execution/ledger record; only the raw CSV is
    # removed. Failure-tolerant.
    def finalize_import!(batch)
      Import.find_by(id: batch.import_id)&.destroy
    rescue StandardError => e
      Rails.logger.warn("[FollowImport::BatchExecutionWorker] failed to finalize import for batch #{batch.id}: #{e.class}: #{e.message}")
    end

    def import_for(batch)
      Import.find_by(id: batch.import_id)
    end

    def observation(batch, candidate_count, gate)
      gate.observation.merge('batch_id' => batch.id, 'candidates' => candidate_count)
    end

    def noteworthy_local_load_enforcement?
      return false unless @local_load&.enabled
      return true unless @local_load.configured
      return true if @local_load.fallback_used
      return true if @dispatch_load_deferred

      @local_load.effective_budget < @local_load.base_budget
    end

    def log_local_load_enforcement(batch)
      return unless noteworthy_local_load_enforcement?

      Rails.logger.info(
        "[FollowImport::BatchExecutionWorker] local_load_enforcement #{
          {
            batch_id: batch.id,
            local_load_state: @local_load.decision&.state,
            base_budget: @local_load.base_budget,
            effective_budget: @local_load.effective_budget,
            fallback_used: @local_load.fallback_used,
            load_deferred: @dispatch_load_deferred,
          }.to_json
        }"
      )
    end

    # Load and global backlog MUST be read before any claim/enqueue so the
    # baseline is not contaminated by work this pass just created.
    def capture_pre_dispatch_snapshot(batch, observed_at)
      {
        observed_at: observed_at,
        load_snapshot: FollowImport::LoadSnapshot.capture,
        batch_pending_before: FollowImport::DispatchCounts.pending_for(batch),
        global_pending_count: FollowImport::DispatchCounts.global_pending,
        active_batch_count: FollowImport::DispatchCounts.active_batches,
      }
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('dispatch_snapshot', e)
      {
        observed_at: observed_at,
        load_snapshot: nil,
        batch_pending_before: nil,
        global_pending_count: nil,
        active_batch_count: nil,
      }
    end

    def record_dispatch_observation(batch, snapshot)
      FollowImport::DispatchObserver.record(
        batch: batch,
        observed_at: snapshot[:observed_at],
        candidate_count: @dispatch_candidate_count,
        claimed_count: @dispatch_claimed_count,
        load_snapshot: snapshot[:load_snapshot],
        batch_pending_before: snapshot[:batch_pending_before],
        global_pending_count: snapshot[:global_pending_count],
        active_batch_count: snapshot[:active_batch_count],
        pass_error_class: @dispatch_pass_error,
        local_load: @local_load,
        load_deferred: @dispatch_load_deferred
      )
    end
  end
end
