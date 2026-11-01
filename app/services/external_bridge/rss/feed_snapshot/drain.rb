# frozen_string_literal: true

module ExternalBridge
  module RSS
    module FeedSnapshot
      # Imports the tail of the oldest open snapshot for one source.
      #
      # One call applies at most Limits::SNAPSHOT_BATCH_ITEMS keyed items,
      # then the worker enqueues itself when any open snapshot remains.
      # Item upsert and the cursor commit in one transaction, and the cursor
      # update matches the lease token. A raise before that update rolls the
      # item back. A retry upserts the same resource key.
      #
      # A position that fails SNAPSHOT_ATTEMPT_CEILING times is isolated and
      # the cursor moves past it. The rest of the generation still runs.
      # Isolated positions are not retried until FeedSnapshot::Retry. A
      # failed snapshot whose cursor has not finished blocks newer
      # generations so their items cannot land first.
      #
      # Subscriptions created at or after the snapshot receive only the
      # history page. Catch-up for a pause is FeedSnapshot::CatchUp, one
      # batch per job.
      class Drain
        class LeaseLost < ExternalBridge::Error
          def initialize
            super(:snapshot_lease_lost)
          end
        end

        # :idle nothing open, :busy lease held, :blocked older remainder,
        # :ok a batch ran.
        def advance!(source_id)
          snapshot = next_snapshot(source_id)
          return :idle if snapshot.nil?
          return blocked!(snapshot) if snapshot.blocked_remainder?

          token = snapshot.claim_lease!
          return :busy if token.nil?

          handoff = false
          begin
            handoff = apply_batch!(snapshot, token)
          rescue LeaseLost
            handoff = still_owned?(snapshot, token)
          rescue StandardError => e
            handoff = recover_error!(snapshot, token, e)
          ensure
            snapshot.release_lease!(token)
          end
          FeedSnapshotDrainWorker.perform_async(source_id) if handoff
          :ok
        end

        # Continued subscriptions (created before this response) receive
        # every position. A subscription created later receives only the
        # history page.
        def project_item!(snapshot, resource, position)
          return if resource.nil?

          history = history_positions(snapshot).include?(position)
          audience(snapshot).each do |subscription|
            next if subscription.created_at >= snapshot.created_at && !history

            Materialize.new.call(subscription: subscription, resources: [resource], retries: false)
          rescue StandardError => e
            Rails.logger.info("[ExternalBridge::RSS] snapshot projection skipped subscription=#{subscription.id} code=#{e.class}")
          end
        end

        def catch_up!(subscription)
          CatchUp.enqueue!(subscription)
        end

        private

        def next_snapshot(source_id)
          scope = ExternalFeedSnapshot.where(external_source_id: source_id)
          blocker = scope.where(state: 'failed').where('next_index < item_count').order(:generation, :id).first
          return blocker if blocker

          scope.open.order(:generation, :id).first
        end

        def blocked!(snapshot)
          RefreshLog.emit(
            'snapshot',
            source_id: snapshot.external_source_id,
            snapshot_id: snapshot.id,
            outcome: 'snapshot_blocked',
            snapshot_items: snapshot.item_count - snapshot.next_index,
            isolated: snapshot.isolated_entries.size
          )
          :blocked
        end

        def still_owned?(snapshot, token)
          ExternalFeedSnapshot.exists?(id: snapshot.id, lease_token: token, state: ExternalFeedSnapshot::OPEN_STATES)
        end

        def recover_error!(snapshot, token, error)
          code = error_code(error)
          attempts = snapshot.note_attempt!(code, token)
          return false if attempts.nil?
          return isolate!(snapshot, token, code) if attempts >= Limits::SNAPSHOT_ATTEMPT_CEILING

          raise error
        end

        def isolate!(snapshot, token, code)
          return false unless snapshot.isolate_current!(token, code)

          RefreshLog.emit(
            'snapshot',
            source_id: snapshot.external_source_id,
            snapshot_id: snapshot.id,
            outcome: 'snapshot_isolated',
            isolated: snapshot.isolated_entries.size,
            error_code: code
          )
          ExternalFeedSnapshot.open.where(external_source_id: snapshot.external_source_id).exists?
        end

        def another_open?(source_id)
          ExternalFeedSnapshot.open.where(external_source_id: source_id).exists?
        end

        def apply_batch!(snapshot, token)
          return apply_retry_batch!(snapshot, token) if snapshot.retry_position_list.any?

          skip_prefix!(snapshot, token)
          snapshot.reload
          return another_open?(snapshot.external_source_id) if done?(snapshot)
          return stop_for_batch_limit!(snapshot, token) if snapshot.batch_count >= Limits::SNAPSHOT_MAX_BATCHES

          before = snapshot.next_index
          import_slice!(snapshot, token, before)
          snapshot.reload
          raise Error, :snapshot_stalled if snapshot.next_index == before && snapshot.open?

          bump_batch!(snapshot, token)
          snapshot.reload
          snapshot.finish!(token) if snapshot.open? && snapshot.next_index >= snapshot.item_count
          snapshot.reload
          snapshot.open? || another_open?(snapshot.external_source_id)
        end

        def done?(snapshot)
          !snapshot.open? || snapshot.next_index >= snapshot.item_count
        end

        def stop_for_batch_limit!(snapshot, token)
          snapshot.fail!('snapshot_batch_limit', token)
          false
        end

        def import_slice!(snapshot, token, start_index)
          finish = [start_index + Limits::SNAPSHOT_BATCH_ITEMS, snapshot.item_count].min
          positions = (start_index...finish).to_a
          return if positions.empty? || snapshot.body.nil?

          items = Parser.parse_positions!(snapshot.body.to_s, positions)
          positions.each_with_index do |position, index|
            apply_position!(snapshot, token, position, items[index])
          end
        end

        def apply_position!(snapshot, token, position, item)
          ApplicationRecord.transaction do
            locked = ExternalFeedSnapshot.lock.find(snapshot.id)
            raise LeaseLost unless lease_current?(locked, token)
            return if !locked.open? || locked.next_index != position

            write_item!(locked, item, position)
            before_progress!(locked)
            raise LeaseLost unless locked.advance_cursor!(token, position)
          end
        end

        def apply_retry_batch!(snapshot, token)
          return false if snapshot.body.nil?

          positions = snapshot.retry_position_list.first(Limits::SNAPSHOT_BATCH_ITEMS)
          items = Parser.parse_positions!(snapshot.body.to_s, positions)
          positions.each_with_index do |position, index|
            apply_retry_position!(snapshot, token, position, items[index])
          end
          snapshot.reload
          snapshot.finish!(token) if snapshot.open? && snapshot.retry_position_list.empty? && snapshot.next_index >= snapshot.item_count
          snapshot.reload
          snapshot.open? || another_open?(snapshot.external_source_id)
        end

        def apply_retry_position!(snapshot, token, position, item)
          ApplicationRecord.transaction do
            locked = ExternalFeedSnapshot.lock.find(snapshot.id)
            raise LeaseLost unless lease_current?(locked, token)

            remaining = locked.retry_position_list
            return unless remaining.delete(position)

            isolated = locked.isolated_entries
            if item && superseded?(locked, item)
              isolated << { 'position' => position, 'code' => 'snapshot_superseded' }
            elsif item
              write_item!(locked, item, position)
            end
            before_progress!(locked)
            raise LeaseLost unless write_retry!(locked, token, remaining, isolated)
          end
        end

        def write_retry!(snapshot, token, remaining, isolated)
          ExternalFeedSnapshot.where(id: snapshot.id, lease_token: token, state: ExternalFeedSnapshot::OPEN_STATES).update_all(
            [
              'retry_positions = ?::jsonb, isolated_positions = ?::jsonb, lease_expires_at = ?, updated_at = ?',
              remaining.to_json,
              isolated.to_json,
              Time.current + Limits::SNAPSHOT_LEASE,
              Time.current,
            ]
          ) == 1
        end

        # A newer finished generation already had its turn. Do not overwrite
        # a resource it wrote. A missing resource is still imported: that key
        # was not in the newer body.
        def superseded?(snapshot, item)
          return false unless ExternalFeedSnapshot.where(external_source_id: snapshot.external_source_id, state: %w(complete incomplete)).where('generation > ?', snapshot.generation).exists?

          resource = stored_resource(snapshot.external_source, item)
          resource.present? && resource.fetched_at.present? && resource.fetched_at > snapshot.created_at
        end

        def write_item!(snapshot, item, position)
          return if item.nil?

          Ingest.new.hold_feed_lock(snapshot.external_source.canonical_key)
          resource = Ingest.new.upsert_item!(snapshot.external_source, item, lock: false)
          project_item!(snapshot, resource, position)
        end

        # Test seam. The item savepoint has run and the cursor has not.
        def before_progress!(_snapshot)
          nil
        end

        def lease_current?(snapshot, token)
          snapshot.lease_token == token && snapshot.lease_expires_at.present? && snapshot.lease_expires_at > Time.current
        end

        def skip_prefix!(snapshot, token)
          return if snapshot.history_applied_at.blank?

          history = snapshot.history_position_list
          ApplicationRecord.transaction do
            locked = ExternalFeedSnapshot.lock.find(snapshot.id)
            raise LeaseLost unless lease_current?(locked, token)

            cursor = next_unskipped(locked.next_index, locked.item_count, history)
            return if cursor == locked.next_index
            raise LeaseLost unless locked.skip_to!(token, cursor)
          end
        end

        def next_unskipped(cursor, item_count, history)
          skipped = history.index_with(true)
          cursor += 1 while cursor < item_count && skipped[cursor]
          cursor
        end

        def bump_batch!(snapshot, token)
          ExternalFeedSnapshot.where(id: snapshot.id, lease_token: token).update_all('batch_count = batch_count + 1')
        end

        def audience(snapshot)
          ExternalSubscription.active.where(external_source_id: snapshot.external_source_id).includes(:user)
        end

        def history_positions(snapshot)
          snapshot.history_position_list
        end

        def stored_resource(source, item)
          return nil if item.nil?

          ExternalResource.find_by(protocol: source.protocol, canonical_key: Ingest.new.canonical_resource_key(source, item.key))
        end

        def error_code(error)
          code = error.is_a?(Error) ? error.code : 'snapshot_failed'
          RefreshLog::ERROR_CODES.include?(code) ? code : 'snapshot_failed'
        end
      end
    end
  end
end
