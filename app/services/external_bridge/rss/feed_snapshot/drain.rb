# frozen_string_literal: true

module ExternalBridge
  module RSS
    module FeedSnapshot
      # Imports the tail of the oldest open snapshot for one source.
      #
      # One call applies at most Limits::SNAPSHOT_BATCH_ITEMS keyed items,
      # then the worker enqueues itself when any open snapshot remains.
      # Item upsert, projection for subscriptions that already existed, and
      # the cursor commit in one transaction. A raise after the upsert and
      # before the cursor update rolls the item back. A retry upserts the
      # same resource key and does not insert a second row.
      #
      # Subscriptions created at or after the snapshot are the initial
      # import. They receive the history page from Subscribe or from
      # Materialize, not the tail. A deleting or paused subscription is not
      # active, so it is not in the continued set. Catch-up on resume
      # projects rows the cursor already passed while the subscription was
      # paused, and only for snapshots newer than that subscription.
      class Drain
        class LeaseLost < ExternalBridge::Error
          def initialize
            super(:snapshot_lease_lost)
          end
        end

        # :idle nothing open, :busy lease held, :ok a batch ran.
        def advance!(source_id)
          ExternalFeedSnapshot.purge_expired!
          snapshot = oldest_open(source_id)
          return :idle if snapshot.nil?

          token = snapshot.claim_lease!
          return :busy if token.nil?

          handoff = false
          begin
            handoff = apply_batch!(snapshot, token)
          rescue LeaseLost
            handoff = ExternalFeedSnapshot.open.where(external_source_id: source_id).exists?
          rescue StandardError => e
            failed = snapshot.note_attempt!(error_code(e))
            raise unless failed

            handoff = another_open?(source_id)
          ensure
            snapshot.release_lease!(token)
          end
          FeedSnapshotDrainWorker.perform_async(source_id) if handoff
          :ok
        end

        # Continued subscriptions (created before this response) receive
        # every position. A subscription created later is the initial import
        # and receives only the history page, so the tail does not become
        # backfill and a resubscribe does not revive the whole snapshot.
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

        # Projects snapshot resources this subscription missed while paused.
        # Does not insert resources and does not move the shared cursor.
        def catch_up!(subscription)
          return unless subscription&.state == 'active'

          bodies_for(subscription).each do |snapshot|
            catch_up_snapshot(snapshot, subscription)
          end
        end

        private

        def oldest_open(source_id)
          ExternalFeedSnapshot.open.where(external_source_id: source_id).order(:generation, :id).first
        end

        def another_open?(source_id)
          ExternalFeedSnapshot.open.where(external_source_id: source_id).exists?
        end

        def apply_batch!(snapshot, token)
          skip_prefix!(snapshot, token)
          snapshot.reload
          return another_open?(snapshot.external_source_id) if done?(snapshot)
          return stop_for_batch_limit!(snapshot) if snapshot.batch_count >= Limits::SNAPSHOT_MAX_BATCHES

          before = snapshot.next_index
          import_slice!(snapshot, token, before)
          snapshot.reload
          raise Error, :snapshot_stalled if snapshot.next_index == before && snapshot.open?

          bump_batch!(snapshot, token)
          snapshot.reload
          snapshot.complete!(token) if snapshot.open? && snapshot.next_index >= snapshot.item_count
          snapshot.reload
          snapshot.open? || another_open?(snapshot.external_source_id)
        end

        def done?(snapshot)
          !snapshot.open? || snapshot.next_index >= snapshot.item_count
        end

        def stop_for_batch_limit!(snapshot)
          snapshot.fail!('snapshot_batch_limit')
          another_open?(snapshot.external_source_id)
        end

        def import_slice!(snapshot, token, start_index)
          finish = [start_index + Limits::SNAPSHOT_BATCH_ITEMS, snapshot.item_count].min
          positions = (start_index...finish).to_a
          return if positions.empty?

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

            Ingest.new.hold_feed_lock(locked.external_source.canonical_key)
            resource = Ingest.new.upsert_item!(locked.external_source, item, lock: false) if item
            project_item!(locked, resource, position)
            before_progress!(locked)
            advance_cursor!(locked, position)
          end
        end

        # Test seam. The item savepoint has run and the cursor has not.
        def before_progress!(_snapshot)
          nil
        end

        def lease_current?(snapshot, token)
          snapshot.lease_token == token && snapshot.lease_expires_at.present? && snapshot.lease_expires_at > Time.current
        end

        def advance_cursor!(snapshot, position)
          now = Time.current
          attributes = { next_index: position + 1, lease_expires_at: now + Limits::SNAPSHOT_LEASE }
          if position + 1 >= snapshot.item_count
            attributes.merge!(state: 'complete', completed_at: now, lease_token: nil, lease_expires_at: nil)
          end
          snapshot.update!(attributes)
        end

        def skip_prefix!(snapshot, token)
          return if snapshot.history_applied_at.blank?

          history = snapshot.history_position_list
          ApplicationRecord.transaction do
            locked = ExternalFeedSnapshot.lock.find(snapshot.id)
            raise LeaseLost unless lease_current?(locked, token)

            cursor = next_unskipped(locked.next_index, locked.item_count, history)
            return if cursor == locked.next_index

            attributes = { next_index: cursor, lease_expires_at: Time.current + Limits::SNAPSHOT_LEASE }
            if cursor >= locked.item_count
              attributes.merge!(state: 'complete', completed_at: Time.current, lease_token: nil, lease_expires_at: nil)
            end
            locked.update!(attributes)
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

        def bodies_for(subscription)
          ExternalFeedSnapshot.where(external_source_id: subscription.external_source_id).where('created_at > ?', subscription.created_at).where.not(body: nil).order(:generation, :id)
        end

        def catch_up_snapshot(snapshot, subscription)
          position = 0
          while position < snapshot.item_count
            finish = [position + Limits::SNAPSHOT_BATCH_ITEMS, snapshot.item_count].min
            project_missing!(snapshot, subscription, (position...finish).to_a)
            position = finish
          end
        end

        def project_missing!(snapshot, subscription, positions)
          items = Parser.parse_positions!(snapshot.body.to_s, positions)
          resources = items.filter_map { |item| stored_resource(snapshot.external_source, item) }
          missing = resources.reject { |resource| projected?(subscription, resource) }
          return if missing.empty?

          Materialize.new.call(subscription: subscription, resources: missing, retries: false)
        end

        def stored_resource(source, item)
          return nil if item.nil?

          ExternalResource.find_by(protocol: source.protocol, canonical_key: Ingest.new.canonical_resource_key(source, item.key))
        end

        def projected?(subscription, resource)
          ExternalStatusProjection.exists?(user_id: subscription.user_id, external_resource_id: resource.id)
        end

        def error_code(error)
          code = error.is_a?(Error) ? error.code : 'snapshot_failed'
          RefreshLog::ERROR_CODES.include?(code) ? code : 'snapshot_failed'
        end
      end
    end
  end
end
