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
      # pending: cursor saved, no live lease.
      # running: this token owns the row.
      # done: the mark sits on the newest snapshot that was finished, and
      # nothing later had a body.
      # stopped: the subscription was not active. The mark stays.
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

          more = false
          begin
            more = step!(row, token)
          rescue LeaseLost
            more = ExternalFeedCatchUp.exists?(id: row.id, lease_token: token)
          ensure
            row.release!(token)
          end
          FeedSnapshotCatchUpWorker.perform_async(subscription_id) if more
          :ok
        end

        private

        def live?(row)
          row.persisted? && row.state == 'running' && row.lease_token.present? && row.lease_expires_at.present? && row.lease_expires_at > Time.current
        end

        def step!(row, token)
          subscription = ExternalSubscription.find_by(id: row.external_subscription_id)
          return stop!(row, token) unless active?(subscription)

          note_purged!(row)
          snapshot = select_snapshot(row, subscription)
          return finish!(row, token) if snapshot.nil?

          start = row.external_feed_snapshot_id == snapshot.id ? row.position : 0
          bound = [start + Limits::SNAPSHOT_BATCH_ITEMS, snapshot.item_count].min
          items = snapshot.body.present? ? Parser.parse_positions!(snapshot.body.to_s, (start...bound).to_a) : []
          resources = items.filter_map { |item| stored_resource(snapshot.external_source, item) }
          before_catch_up_write!(row)
          write_batch!(row, token, snapshot: snapshot, subscription: subscription, resources: resources, bound: bound)
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
          more = false
          rolled_back = false
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

            more = advance_locked!(locked, token, snapshot, bound, current)
          end
          return stop!(row, token) if rolled_back

          more
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

        def advance_locked!(row, token, snapshot, bound, subscription)
          nxt = bound
          finished = nxt >= snapshot.item_count
          later = later_bodies(subscription, snapshot.generation).exists?
          state = finished && !later ? 'done' : 'pending'
          updated = ExternalFeedCatchUp.where(id: row.id, lease_token: token).update_all(
            external_feed_snapshot_id: snapshot.id,
            generation: snapshot.generation,
            position: finished ? snapshot.item_count : nxt,
            state: state,
            updated_at: Time.current
          )
          raise LeaseLost unless updated == 1

          !finished || later
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
