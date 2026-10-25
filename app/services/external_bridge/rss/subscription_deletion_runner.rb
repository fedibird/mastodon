# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Runs the physical removal behind an accepted unsubscribe, in small
    # transactions, and can be started again from any point.
    #
    # Each batch is one transaction that
    #   - locks the owner's ExternalSubscriptionDeletion FOR UPDATE (so two
    #     workers take turns, never overlap),
    #   - reads the next BATCH_SIZE status ids of the subscription through the
    #     indexed external_subscription_id, ordered by status_id,
    #   - runs the existing ProjectionPurge (E4 retirement, physical DELETE
    #     under SET LOCAL, Streaming delete events, link-boost state),
    #   - adds the number of rows that DELETE really removed to deleted_count.
    # The counter and the delete commit together, so a crash, a retry, or a
    # second worker can neither double count nor lose a row. Wrapper removals,
    # cache entries, and search documents follow the commit, as they do for any
    # ProjectionPurge. RemoveStatusService and discard are never used.
    #
    # The subscription row is destroyed last, in the finishing transaction, and
    # only when no projection of it is left in the database. The record is not
    # a foreign key of that row, so completion keeps the progress visible.
    #
    # A run stops after MAX_BATCHES or TIME_BUDGET and reports :continue so the
    # worker queues itself again; a long delete never holds a Sidekiq thread.
    class SubscriptionDeletionRunner
      DEFAULT_BATCH_SIZE = 100
      MIN_BATCH_SIZE = 10
      MAX_BATCH_SIZE = 1000
      MAX_BATCHES = 50
      TIME_BUDGET = 20.seconds
      LEASE = 5.minutes
      SIDE_BATCH = 500
      MAX_AUTO_ATTEMPTS = 5
      BACKOFF = [30.seconds, 2.minutes, 10.minutes, 30.minutes, 2.hours].freeze

      def self.batch_size
        configured = ENV.fetch('EXTERNAL_RSS_DELETION_BATCH_SIZE', DEFAULT_BATCH_SIZE).to_i
        configured.clamp(MIN_BATCH_SIZE, MAX_BATCH_SIZE)
      end

      # Who may run a record. A job is an invitation, not a right: it can arrive
      # twice, late, or after the record has moved on.
      #   queued, running  run (two workers take turns on the row lock; `running`
      #                    is also how a record whose worker died is taken over
      #                    once the scheduler pushes it again)
      #   failed           never: the scheduler turns a due `failed` record into
      #                    `queued` itself, and the owner's retry does the same
      #                    for a record whose attempts are used up. A stale job
      #                    must not bypass that
      #   completed        nothing to do
      #
      # @return [Symbol] :completed, :continue, :failed, :gone, :stopped
      def call(deletion_id)
        started = monotonic
        deletion = claim!(deletion_id)
        return :gone if deletion.nil?
        return :completed if deletion.completed?
        return :stopped if deletion.failed?

        SubscriptionDeletionLog.emit('started', log_fields(deletion))
        drain(deletion.id, started)
      rescue StandardError => e
        fail!(deletion_id, e)
      end

      private

      def drain(deletion_id, started)
        batches = 0
        loop do
          step = purge_batch!(deletion_id)
          return :gone if step == :gone
          return :completed if step == :completed
          return :stopped if step == :stopped

          if step == :empty
            finished = finish!(deletion_id, started)
            return finished unless finished == :more
          else
            batches += 1
          end
          return :continue if batches >= MAX_BATCHES || monotonic - started >= TIME_BUDGET
        end
      end

      def claim!(deletion_id)
        ApplicationRecord.transaction do
          deletion = ExternalSubscriptionDeletion.lock.find_by(id: deletion_id)
          next nil if deletion.nil?
          next deletion if deletion.completed? || deletion.failed?

          now = Time.current
          attributes = { state: 'running', next_run_at: now + LEASE, updated_at: now, last_error_code: nil }
          attributes[:started_at] = shifted_start(deletion, now)
          attributes[:total_count] = projection_scope(deletion).count if deletion.total_count.nil?
          deletion.update_columns(attributes)
          deletion
        end
      end

      # Time spent waiting (a failed run, a lost worker) is not processing time.
      # Moving the start forward keeps the observed speed honest.
      def shifted_start(deletion, now)
        return deletion.started_at || now if deletion.last_progress_at.nil? || deletion.started_at.nil?

        idle = now - deletion.last_progress_at
        idle > 60 ? deletion.started_at + idle : deletion.started_at
      end

      def purge_batch!(deletion_id)
        ids = []
        outcome = nil
        result = nil
        ApplicationRecord.transaction do
          deletion = ExternalSubscriptionDeletion.lock.find_by(id: deletion_id)
          if deletion.nil?
            outcome = :gone
          elsif deletion.completed?
            outcome = :completed
          elsif deletion.failed?
            outcome = :stopped
          else
            ids = projection_scope(deletion).order(:status_id).limit(self.class.batch_size).pluck(:status_id)
            if ids.empty?
              outcome = :empty
            else
              result = ProjectionPurge.purge_ids_in_transaction!(ids, route_targets: deletion.route_targets)
              record_progress!(deletion, result[:deleted])
              outcome = :batch
            end
          end
        end
        ProjectionPurge.finish_purge!(ids, result[:removals]) if result
        outcome
      end

      def record_progress!(deletion, deleted)
        now = Time.current
        total = deletion.deleted_count + deleted
        deletion.update_columns(
          deleted_count: total,
          total_count: [deletion.total_count.to_i, total].max,
          last_progress_at: now,
          next_run_at: now + LEASE,
          updated_at: now
        )
        SubscriptionDeletionLog.emit(
          'batch',
          log_fields(deletion).merge(batch: deleted, deleted: total, remaining: [deletion.total_count.to_i - total, 0].max)
        )
      end

      # No projection is left. Clear what hangs off the subscription in small
      # transactions first, then take the last locks, check once more under
      # them, and destroy the row.
      def finish!(deletion_id, started)
        deletion = ExternalSubscriptionDeletion.find_by(id: deletion_id)
        return :gone if deletion.nil?

        clear_side_rows!(deletion)
        completed = false
        ApplicationRecord.transaction do
          locked = ExternalSubscriptionDeletion.lock.find_by(id: deletion_id)
          next if locked.nil? || locked.completed?

          subscription = ExternalSubscription.lock.find_by(id: locked.external_subscription_id)
          if subscription && ExternalStatusProjection.where(external_subscription_id: subscription.id).exists?
            next
          end

          destroy_subscription!(locked, subscription)
          complete!(locked, started)
          completed = true
        end
        completed ? :completed : :more
      end

      def destroy_subscription!(deletion, subscription)
        return if subscription.nil?

        suppression_scope(deletion).delete_all
        ExternalProjectionFailure.where(external_subscription_id: subscription.id).delete_all
        subscription.destroy!
      end

      def complete!(deletion, started)
        now = Time.current
        deletion.update_columns(
          state: 'completed',
          total_count: [deletion.total_count.to_i, deletion.deleted_count].max,
          finished_at: now,
          next_run_at: nil,
          last_error_code: nil,
          updated_at: now
        )
        SubscriptionDeletionLog.emit(
          'completed',
          log_fields(deletion).merge(deleted: deletion.deleted_count, remaining: 0, elapsed_ms: elapsed_ms(started))
        )
      end

      def clear_side_rows!(deletion)
        delete_in_slices(suppression_scope(deletion), ExternalProjectionSuppression)
        delete_in_slices(ExternalProjectionFailure.where(external_subscription_id: deletion.external_subscription_id), ExternalProjectionFailure)
      end

      def delete_in_slices(scope, model)
        loop do
          removed = model.where(id: scope.limit(SIDE_BATCH).select(:id)).delete_all
          break if removed < SIDE_BATCH
        end
      end

      def suppression_scope(deletion)
        ExternalProjectionSuppression.where(
          user_id: deletion.user_id,
          external_resource_id: ExternalResource.where(external_source_id: deletion.external_source_id).select(:id)
        )
      end

      def projection_scope(deletion)
        ExternalStatusProjection.where(external_subscription_id: deletion.external_subscription_id)
      end

      def fail!(deletion_id, error)
        code = error_code(error)
        failed = nil
        ApplicationRecord.transaction do
          deletion = ExternalSubscriptionDeletion.lock.find_by(id: deletion_id)
          next if deletion.nil? || deletion.completed?

          attempts = deletion.attempt_count + 1
          now = Time.current
          deletion.update_columns(
            state: 'failed',
            attempt_count: attempts,
            last_error_code: code,
            next_run_at: attempts >= MAX_AUTO_ATTEMPTS ? nil : now + BACKOFF.fetch(attempts - 1, BACKOFF.last),
            updated_at: now
          )
          failed = deletion
        end
        SubscriptionDeletionLog.emit('failed', log_fields(failed).merge(error_class: error.class, error_code: code)) if failed
        failed ? :failed : :gone
      rescue StandardError => e
        SubscriptionDeletionLog.emit('failed', deletion_id: deletion_id.to_i, error_class: e.class)
        :failed
      end

      def error_code(error)
        case error
        when ActiveRecord::ActiveRecordError then 'database_error'
        when Redis::BaseError then 'queue_error'
        else 'unexpected_error'
        end
      end

      def log_fields(deletion)
        {
          job_id: deletion.id,
          subscription_id: deletion.external_subscription_id,
          user_id: deletion.user_id,
          attempt: deletion.attempt_count,
          state: deletion.state,
          total: deletion.total_count,
        }
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_ms(started)
        ((monotonic - started) * 1000).to_i
      end
    end
  end
end
