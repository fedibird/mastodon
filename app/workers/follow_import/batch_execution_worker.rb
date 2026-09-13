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
# Rescheduling is gated on FORWARD PROGRESS: the next pass is only enqueued when
# at least one target was claimed+executed this pass. A pass that claims nothing
# (e.g. the gate left everything pending, or nothing was recoverable) stops the
# chain instead of spinning — those targets wait for a future explicit/manual/
# policy-triggered recheck rather than being re-evaluated on a tight loop.
module FollowImport
  class BatchExecutionWorker
    include Sidekiq::Worker

    sidekiq_options queue: 'pull', retry: 5

    def perform(batch_id)
      batch = FollowImportBatch.find_by(id: batch_id)
      return if batch.nil?

      account = batch.subject&.account
      return if account.nil?

      now        = Time.now.utc
      candidates = batch.targets.where(state: :pending).order(:position).limit(FollowImport::ExecutionPolicy.execution_batch_size).to_a
      return if candidates.empty?

      progress = execute_pass(batch, account, candidates, now)

      # Only continue while making forward progress. Zero progress means the
      # remaining pending targets are all gate-deferred (or unrecoverable); stop
      # the automatic chain rather than re-evaluate them in a loop.
      reschedule(batch) if progress.positive? && batch.targets.where(state: :pending).exists?
    end

    private

    def execute_pass(batch, account, candidates, now)
      gate = FollowImport::ExecutionGate.for_account(account, now: now)
      Rails.logger.info("[FollowImport::BatchExecutionWorker] #{observation(batch, candidates.size, gate).to_json}")

      return 0 unless gate.execute?

      resolver    = FollowImport::ImportUnitResolver.new(import_for(batch))
      transitions = FollowImport::TargetTransitionService.new
      progress    = 0

      candidates.each do |target|
        work = resolver.work_for(target)
        next if work.nil? # address/options unrecoverable (rare) — leave pending

        transitions.mark_queued(target, at: now)
        # Only this pass's successful claim (pending -> queued) counts and
        # enqueues; a concurrent pass that already claimed it is a no-op here.
        next unless target.saved_change_to_state? && target.state_queued?

        enqueue_follow(account, target, work, batch)
        progress += 1
      end

      progress
    end

    def enqueue_follow(account, target, work, batch)
      options = work[:options].merge(import_batch_id: batch.id, follow_import_target_id: target.id)
      Import::RelationshipWorker.perform_async(account.id, work[:acct], 'follow', options.stringify_keys)
    end

    def reschedule(batch)
      self.class.perform_in(FollowImport::ExecutionPolicy.execution_reschedule_in, batch.id)
    end

    def import_for(batch)
      Import.find_by(id: batch.import_id)
    end

    def observation(batch, candidate_count, gate)
      gate.observation.merge('batch_id' => batch.id, 'candidates' => candidate_count)
    end
  end
end
