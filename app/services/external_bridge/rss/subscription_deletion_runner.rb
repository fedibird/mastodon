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
    #     under SET LOCAL, link-boost state) and inserts one effect row per
    #     deleted status id, with home/list destinations only when a stream
    #     delete is due,
    #   - adds the number of rows that DELETE really removed to deleted_count.
    # The counter, the delete, and the effect rows commit together. Cache,
    # search, and the stream enqueue are stamped separately after that commit.
    # A failure of one leaves the others free to succeed, and the effect row
    # stays until each required stamp is set. Further deletes pause while
    # EFFECTS_CAP rows are still open, so a refused enqueue cannot grow without
    # a bound. RemoveStatusService and discard are never used.
    #
    # The subscription row is destroyed last, only when no projection is left
    # and no effect row is still open. The record is not a foreign key of that
    # row, so completion keeps the progress visible.
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
      # How long to wait before asking again, when deleted statuses still have
      # cache, search, or a stream delete outstanding.
      EFFECTS_RETRY = 30.seconds
      # Open effect rows at which more physical deletes wait. One batch can
      # land past this by a single batch, and no further batch is taken until
      # the open rows drop below it.
      EFFECTS_CAP = 1_000
      FLUSH_SLICE = 100
      SIDE_BATCH = 500
      MAX_AUTO_ATTEMPTS = 5
      BACKOFF = [30.seconds, 2.minutes, 10.minutes, 30.minutes, 2.hours].freeze

      # Test seam for real races. Production code never listens.
      def self.checkpoint(name)
        ActiveSupport::Notifications.instrument('external_bridge.rss_deletion', name: name)
      end

      def self.batch_size
        configured = ENV.fetch('EXTERNAL_RSS_DELETION_BATCH_SIZE', DEFAULT_BATCH_SIZE).to_i
        configured.clamp(MIN_BATCH_SIZE, MAX_BATCH_SIZE)
      end

      # True when this deletion already has EFFECTS_CAP open effect rows.
      # offset/exists avoids counting a large set; the cap keeps the set small.
      def self.effects_backlogged?(deletion_id)
        ExternalSubscriptionDeletionEffect.outstanding
                                          .where(external_subscription_deletion_id: deletion_id)
                                          .offset(EFFECTS_CAP - 1)
                                          .exists?
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
      # @return [Symbol] :completed, :continue, :effects_pending, :failed, :gone, :stopped
      def call(deletion_id)
        # Outside the claim transaction. A Redis error here must not fail the
        # deletion, and must not run from an after_commit callback.
        SubscriptionRemovedNotice.push!(ExternalSubscriptionDeletion.find_by(id: deletion_id))
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

          if step == :backlog
            flush_pending_effects!(deletion_id)
            if effects_pending?(deletion_id)
              hold_for_effects!(deletion_id)
              return :effects_pending
            end

            next
          elsif step == :empty
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
          elsif self.class.effects_backlogged?(deletion.id)
            outcome = :backlog
          else
            ids = projection_scope(deletion).order(:status_id).limit(self.class.batch_size).pluck(:status_id)
            if ids.empty?
              outcome = :empty
            else
              result = ProjectionPurge.purge_ids_in_transaction!(
                ids,
                route_targets: deletion.route_targets,
                schedule_deletes: false,
                deletion_id: deletion.id
              )
              remember_effects!(deletion, ids, result[:captures])
              record_progress!(deletion, result[:deleted])
              outcome = :batch
            end
          end
        end
        release_committed_batch!(deletion_id, result[:removals], media: result[:media]) if result
        outcome
      end

      # Every deleted status id, not only those that need a stream event.
      # destinations is null for a personal projection. Inserts are new rows;
      # the deletion row itself is not rewritten.
      def remember_effects!(deletion, status_ids, captures)
        destinations = {}
        Array(captures).each do |row|
          next unless row.is_a?(Hash) && row['status_id'].present?

          destinations[row['status_id'].to_s] = row['destinations']
        end
        now = Time.current
        rows = status_ids.map(&:to_i).uniq.reject(&:zero?).map do |status_id|
          {
            external_subscription_deletion_id: deletion.id,
            status_id: status_id,
            destinations: destinations[status_id.to_s],
            created_at: now,
            updated_at: now,
          }
        end
        ExternalSubscriptionDeletionEffect.insert_all(rows) if rows.any?
      end

      # Outside the batch transaction. Nothing here may raise into the runner:
      # the rows are already gone, and a Redis error must not mark the record
      # failed or skip the next batch.
      def release_committed_batch!(deletion_id, removals, media: nil)
        begin
          LinkSharing::Retire.enqueue_removals(removals)
        rescue StandardError => e
          Rails.logger.warn("[ExternalBridge] deletion side effect step=wrapper_removal error=#{e.class}")
        end
        ProjectionPurge.destroy_detached_media!(media)
        flush_pending_effects!(deletion_id)
      end

      # Cache, search, and stream are stamped on their own. A cache error does
      # not skip search, and a stream job id does not erase a status whose
      # cache or search clear has not succeeded.
      # One pass. A row that is still open is not selected again in this pass,
      # so a cache or search error cannot spin. The next run starts over.
      def flush_pending_effects!(deletion_id)
        deletion = ExternalSubscriptionDeletion.find_by(id: deletion_id)
        return if deletion.nil?

        last_id = 0
        loop do
          rows = ExternalSubscriptionDeletionEffect.outstanding
                                                   .where(external_subscription_deletion_id: deletion_id)
                                                   .where('id > ?', last_id)
                                                   .order(:id)
                                                   .limit(FLUSH_SLICE)
                                                   .to_a
          break if rows.empty?

          last_id = rows.last.id
          stamp_cache!(rows)
          stamp_search!(rows)
          stamp_stream!(deletion, rows)
          drop_finished_effects!(rows.map(&:id))
        end
      rescue StandardError => e
        Rails.logger.warn("[ExternalBridge] deletion side effect step=effects error=#{e.class}")
      end

      def stamp_cache!(rows)
        pending = rows.select { |row| row.cache_cleared_at.nil? }
        done = pending.select { |row| ProjectionPurge.delete_cached_status(row.status_id) }
        mark_effects!(done.map(&:id), :cache_cleared_at)
      end

      def stamp_search!(rows)
        pending = rows.select { |row| row.search_cleared_at.nil? }
        return if pending.empty?
        return unless ProjectionPurge.delete_search_documents(pending.map(&:status_id))

        mark_effects!(pending.map(&:id), :search_cleared_at)
      end

      def stamp_stream!(deletion, rows)
        pending = rows.select { |row| row.destinations.present? && row.stream_enqueued_at.nil? }
        return if pending.empty?

        payloads = pending.map { |row| stream_payload(deletion, row) }
        result = Streaming::Scheduler.push_deletes!(payloads)
        accepted = result[:accepted].map { |row| row['status_id'].to_s }
        discarded = Array(result[:discarded]).filter_map { |row| row.is_a?(Hash) ? row['status_id']&.to_s : nil }
        finished = (accepted + discarded).to_set
        done = pending.select { |row| finished.include?(row.status_id.to_s) }
        mark_stream!(done.map(&:id))
      end

      def stream_payload(deletion, row)
        {
          'user_id' => deletion.user_id.to_s,
          'status_id' => row.status_id.to_s,
          'subscription_id' => deletion.external_subscription_id.to_s,
          'destinations' => row.destinations,
        }
      end

      def mark_effects!(ids, column)
        return if ids.empty?

        ExternalSubscriptionDeletionEffect.where(id: ids).update_all(column => Time.current)
      end

      # Separate from mark_effects! so a kill after Sidekiq has accepted the
      # job, and before this stamp, can be told apart in tests.
      def mark_stream!(ids)
        mark_effects!(ids, :stream_enqueued_at)
      end

      def drop_finished_effects!(ids)
        return if ids.empty?

        ExternalSubscriptionDeletionEffect.where(id: ids)
                                          .where.not(cache_cleared_at: nil)
                                          .where.not(search_cleared_at: nil)
                                          .where('destinations IS NULL OR stream_enqueued_at IS NOT NULL')
                                          .delete_all
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

        # The subscription stays until every captured delete has a job id.
        # Destroying it first would not lose the captures (they are on this
        # row), but the card would say completed while a connected client
        # could still be showing the items.
        flush_pending_effects!(deletion_id)
        if effects_pending?(deletion_id)
          hold_for_effects!(deletion_id)
          return :effects_pending
        end

        self.class.checkpoint(:finish_after_read)
        clear_side_rows!(deletion)
        completed = false
        ApplicationRecord.transaction do
          locked = ExternalSubscriptionDeletion.lock.find_by(id: deletion_id)
          next if locked.nil? || locked.completed? || locked.failed?

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

      def effects_pending?(deletion_id)
        ExternalSubscriptionDeletionEffect.outstanding.where(external_subscription_deletion_id: deletion_id).exists?
      end

      def hold_for_effects!(deletion_id)
        deletion = nil
        ApplicationRecord.transaction do
          deletion = ExternalSubscriptionDeletion.lock.find_by(id: deletion_id)
          next if deletion.nil? || deletion.completed? || deletion.failed?

          now = Time.current
          deletion.update_columns(next_run_at: now + EFFECTS_RETRY, updated_at: now)
        end
        return if deletion.nil? || deletion.completed? || deletion.failed?

        SubscriptionDeletionLog.emit(
          'effects_pending',
          log_fields(deletion).merge(pending: ExternalSubscriptionDeletionEffect.outstanding.where(external_subscription_deletion_id: deletion.id).count)
        )
      end

      # Every slice is its own short transaction that locks the deletion row,
      # checks that this record is still the one running, and only then deletes.
      # The suppressions are keyed by user and source, not by subscription id, so
      # a worker that was slow to get here (and a record that another worker has
      # completed in the meantime) must not reach them: after the subscription is
      # destroyed the same user can subscribe to the same source again and add
      # suppressions that belong to the new subscription. Completion takes the same
      # row lock, so a slice either runs before it or sees `completed` and stops.
      def clear_side_rows!(deletion)
        delete_in_slices(deletion.id, ExternalProjectionSuppression) { |locked| suppression_scope(locked) }
        delete_in_slices(deletion.id, ExternalProjectionFailure) do |locked|
          ExternalProjectionFailure.where(external_subscription_id: locked.external_subscription_id)
        end
      end

      def delete_in_slices(deletion_id, model)
        loop do
          removed = ApplicationRecord.transaction do
            locked = ExternalSubscriptionDeletion.lock.find_by(id: deletion_id)
            next nil if locked.nil? || locked.completed? || locked.failed?

            model.where(id: yield(locked).limit(SIDE_BATCH).select(:id)).delete_all
          end
          break if removed.nil? || removed < SIDE_BATCH
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
