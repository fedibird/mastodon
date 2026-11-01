# frozen_string_literal: true

module ExternalBridge
  module RSS
    module FeedSnapshot
      # One batch of projections a subscriber missed while paused.
      #
      # generation is a high-water mark. The cursor enters a snapshot and
      # never returns to an earlier one, including when that body is purged
      # or the row is gone. position is the next keyed index inside the
      # snapshot named by external_feed_snapshot_id.
      #
      # The cursor moves only through positions the shared source has already
      # committed. A history position is committed when history_applied_at is
      # set. A tail position is committed when next_index has passed it. A
      # retryable isolated position is not committed: the cursor waits there
      # until Retry imports it or marks it snapshot_superseded. A superseded
      # isolate is an explicit gap. A missing resource is never a reason to
      # step over a position the drain has not committed.
      #
      # pending: cursor saved, no live lease. This includes a cursor parked
      # because the next position is not committed yet. That row pins the
      # body. The log line is snapshot_waiting. Drain wakes the job after a
      # committed batch. If it is still waiting, the worker schedules one
      # delayed retry. Manual recovery: Retry.call on the source snapshot
      # that still holds the position, or set this row to stopped to release
      # the pin and accept the gap.
      # running: this token owns the row.
      # done: the mark sits on the newest snapshot that was finished, and
      # nothing later had a body.
      # stopped: the subscription was not active. The mark stays. The pin
      # is released.
      #
      # Resume does not zero the mark. A second enqueue while a batch is in
      # flight, or while the lease has already been released, leaves position
      # and generation alone. Projection and the mark commit together. A
      # lost lease writes nothing.
      class CatchUp
        class LeaseLost < ExternalBridge::Error
          def initialize
            super(:snapshot_lease_lost)
          end
        end

        SUPERSEDED = 'snapshot_superseded'

        def self.enqueue!(subscription)
          new.enqueue!(subscription)
        end

        def self.advance!(subscription_id)
          new.advance!(subscription_id)
        end

        def enqueue!(subscription)
          return unless subscription&.state == 'active'

          row = ExternalFeedCatchUp.find_or_initialize_by(external_subscription_id: subscription.id)
          return if live?(row)

          if row.new_record?
            row.generation = 0
            row.position = 0
            row.external_feed_snapshot_id = nil
          end
          row.state = 'pending'
          row.lease_token = nil
          row.lease_expires_at = nil
          row.save!
          FeedSnapshotCatchUpWorker.perform_async(subscription.id)
        end

        def advance!(subscription_id)
          row = ExternalFeedCatchUp.find_by(external_subscription_id: subscription_id)
          return :idle if row.nil?

          token = row.claim!
          return :busy if token.nil?

          outcome = :ok
          begin
            outcome = step!(row, token)
          rescue LeaseLost
            outcome = ExternalFeedCatchUp.exists?(id: row.id, lease_token: token) ? :busy : :ok
          ensure
            row.release!(token)
          end
          FeedSnapshotCatchUpWorker.perform_async(subscription_id) if outcome == :more
          return :waiting if outcome == :waiting
          return :busy if outcome == :busy

          :ok
        end

        private

        def live?(row)
          row.persisted? && row.state == 'running' && row.lease_token.present? && row.lease_expires_at.present? && row.lease_expires_at > Time.current
        end

        def step!(row, token)
          subscription = ExternalSubscription.find_by(id: row.external_subscription_id)
          unless active?(subscription)
            stop!(row, token)
            return :stop
          end

          note_purged!(row)
          snapshot = select_snapshot(row, subscription)
          if snapshot.nil?
            finish!(row, token)
            return :done
          end

          start = row.external_feed_snapshot_id == snapshot.id ? row.position : 0
          bound = contiguous_ready(snapshot, start)
          positions = (start...bound).to_a + side_history_positions(snapshot, start, bound)
          resources = resources_for(snapshot, positions)
          before_catch_up_write!(row)
          write_batch!(row, token, snapshot: snapshot, subscription: subscription, resources: resources, bound: bound, start: start)
        end

        # Test seam. Runs after the body is read and before the lease is
        # checked again under the row lock.
        def before_catch_up_write!(_row)
          nil
        end

        def write_batch!(row, token, **work)
          snapshot = work.fetch(:snapshot)
          subscription = work.fetch(:subscription)
          resources = work.fetch(:resources)
          bound = work.fetch(:bound)
          start = work.fetch(:start)
          rolled_back = false
          outcome = :done
          ApplicationRecord.transaction do
            locked = ExternalFeedCatchUp.lock.find(row.id)
            raise LeaseLost unless owned?(locked, token)

            current = ExternalSubscription.lock('FOR SHARE').find_by(id: subscription.id)
            unless active?(current)
              rolled_back = true
              raise ActiveRecord::Rollback
            end

            missing = resources.reject { |resource| projected?(current, resource) }
            Materialize.new.call(subscription: current, resources: missing, retries: false) if missing.any?
            unless active?(ExternalSubscription.find_by(id: current.id))
              rolled_back = true
              raise ActiveRecord::Rollback
            end

            outcome = advance_locked!(locked, token, snapshot, bound, start)
          end
          if rolled_back
            stop!(row, token)
            return :stop
          end

          note_waiting!(snapshot, row, start) if outcome == :waiting
          outcome
        end

        def select_snapshot(row, subscription)
          if row.external_feed_snapshot_id
            current = ExternalFeedSnapshot.find_by(id: row.external_feed_snapshot_id)
            if current&.body.present? && row.position < current.item_count && current.generation >= row.generation.to_i
              return current
            end
          end
          later_bodies(subscription, row.generation.to_i).first
        end

        def later_bodies(subscription, generation)
          ExternalFeedSnapshot.where(external_source_id: subscription.external_source_id)
                              .where('created_at > ?', subscription.created_at)
                              .where('generation > ?', generation)
                              .where.not(body: nil)
                              .order(:generation, :id)
        end

        # Exclusive end of the committed prefix, capped at one batch.
        def contiguous_ready(snapshot, start)
          limit = [start + Limits::SNAPSHOT_BATCH_ITEMS, snapshot.item_count].min
          position = start
          position += 1 while position < limit && settled_position?(snapshot, position)
          position
        end

        # History capture already committed these, even when they sit past
        # the first tail position the drain has not reached. The cursor
        # itself stays on that tail position.
        def side_history_positions(snapshot, start, bound)
          room = Limits::SNAPSHOT_BATCH_ITEMS - (bound - start)
          return [] if room <= 0 || snapshot.history_applied_at.blank?

          snapshot.history_position_list.select { |position| position >= bound && settled_position?(snapshot, position) }.sort.first(room)
        end

        def settled_position?(snapshot, position)
          return false if position.negative? || position >= snapshot.item_count

          entry = isolate_at(snapshot, position)
          return false if entry && entry['code'] != SUPERSEDED
          return true if entry
          return true if snapshot.history_applied_at.present? && snapshot.history_position_list.include?(position)

          snapshot.next_index > position
        end

        def isolate_at(snapshot, position)
          snapshot.isolated_entries.find { |entry| entry['position'] == position }
        end

        def resources_for(snapshot, positions)
          return [] if positions.empty? || snapshot.body.blank?

          items = Parser.parse_positions!(snapshot.body.to_s, positions)
          positions.each_with_index.filter_map do |position, index|
            next if superseded_isolate?(snapshot, position)

            stored_resource(snapshot.external_source, items[index])
          end
        end

        def superseded_isolate?(snapshot, position)
          entry = isolate_at(snapshot, position)
          entry.present? && entry['code'] == SUPERSEDED
        end

        def note_purged!(row)
          return if row.external_feed_snapshot_id.nil?

          current = ExternalFeedSnapshot.find_by(id: row.external_feed_snapshot_id)
          return if current.nil? || current.body.present? || row.position >= current.item_count

          RefreshLog.emit(
            'snapshot',
            source_id: current.external_source_id,
            snapshot_id: current.id,
            subscription_id: row.external_subscription_id,
            outcome: 'snapshot_body_purged',
            snapshot_generation: current.generation
          )
        end

        # The shared cursor has not committed `position`. Keep the mark
        # there. Operators see snapshot_waiting. Retry.call resumes a failed
        # remainder or a retryable isolate. Setting the catch-up to stopped
        # releases the pin and leaves the gap.
        def note_waiting!(snapshot, row, position)
          blocked = isolate_at(snapshot, position)
          RefreshLog.emit(
            'snapshot',
            source_id: snapshot.external_source_id,
            snapshot_id: snapshot.id,
            subscription_id: row.external_subscription_id,
            outcome: 'snapshot_waiting',
            snapshot_generation: snapshot.generation,
            snapshot_items: [snapshot.item_count - position, 0].max,
            isolated: blocked && blocked['code'] != SUPERSEDED ? 1 : 0
          )
        end

        def advance_locked!(row, token, snapshot, bound, start)
          waiting = bound == start
          finished = !waiting && bound >= snapshot.item_count
          subscription = ExternalSubscription.find(row.external_subscription_id)
          later = later_bodies(subscription, snapshot.generation).exists?
          state = finished && !later ? 'done' : 'pending'
          position = waiting ? start : bound
          updated = ExternalFeedCatchUp.where(id: row.id, lease_token: token).update_all(
            external_feed_snapshot_id: snapshot.id,
            generation: snapshot.generation,
            position: position,
            state: state,
            updated_at: Time.current
          )
          raise LeaseLost unless updated == 1

          return :waiting if waiting
          return :done if finished && !later

          :more
        end

        def owned?(row, token)
          row.lease_token == token && row.lease_expires_at.present? && row.lease_expires_at > Time.current
        end

        def active?(subscription)
          subscription&.state == 'active' && !subscription.deleting?
        end

        def stop!(row, token)
          ExternalFeedCatchUp.where(id: row.id, lease_token: token).update_all(
            state: 'stopped', lease_token: nil, lease_expires_at: nil, updated_at: Time.current
          )
          false
        end

        def finish!(row, token)
          updated = ExternalFeedCatchUp.where(id: row.id, lease_token: token).update_all(
            state: 'done', lease_token: nil, lease_expires_at: nil, updated_at: Time.current
          )
          raise LeaseLost unless updated == 1

          false
        end

        def stored_resource(source, item)
          return nil if item.nil?

          ExternalResource.find_by(protocol: source.protocol, canonical_key: Ingest.new.canonical_resource_key(source, item.key))
        end

        def projected?(subscription, resource)
          ExternalStatusProjection.exists?(user_id: subscription.user_id, external_resource_id: resource.id)
        end
      end
    end
  end
end
