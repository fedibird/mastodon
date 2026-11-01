# frozen_string_literal: true

module ExternalBridge
  module RSS
    module FeedSnapshot
      # One batch of projections a subscriber missed while paused.
      #
      # The cursor lives on external_feed_catch_ups. Resume enqueues the
      # worker and returns. Each job parses at most SNAPSHOT_BATCH_ITEMS
      # positions of one snapshot, checks the subscription is still active,
      # then enqueues itself when anything remains. A deleting or paused
      # subscription stops the cursor. It does not walk every generation in
      # the request.
      class CatchUp
        def self.enqueue!(subscription)
          new.enqueue!(subscription)
        end

        def self.advance!(subscription_id)
          new.advance!(subscription_id)
        end

        def enqueue!(subscription)
          return unless subscription&.state == 'active'

          row = ExternalFeedCatchUp.find_or_initialize_by(external_subscription_id: subscription.id)
          return if row.persisted? && row.state == 'running' && row.lease_expires_at.present? && row.lease_expires_at > Time.current

          row.update!(state: 'pending', external_feed_snapshot_id: nil, position: 0, lease_token: nil, lease_expires_at: nil)
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
          ensure
            row.release!(token)
          end
          FeedSnapshotCatchUpWorker.perform_async(subscription_id) if more
          :ok
        end

        private

        def step!(row, token)
          subscription = ExternalSubscription.find_by(id: row.external_subscription_id)
          unless active?(subscription)
            stop!(row, token)
            return false
          end

          snapshot = select_snapshot(row, subscription)
          if snapshot.nil?
            finish!(row, token)
            return false
          end

          project_batch!(row, snapshot, subscription)
          advance_row!(row, token, snapshot)
        end

        def active?(subscription)
          subscription&.state == 'active' && !subscription.deleting?
        end

        def select_snapshot(row, subscription)
          scope = bodies(subscription)
          current = scope.find_by(id: row.external_feed_snapshot_id) if row.external_feed_snapshot_id
          return current if current && row.position < current.item_count

          if current
            scope.where('generation > ?', current.generation).order(:generation, :id).first
          else
            scope.order(:generation, :id).first
          end
        end

        def bodies(subscription)
          ExternalFeedSnapshot.where(external_source_id: subscription.external_source_id)
                              .where('created_at > ?', subscription.created_at)
                              .where.not(body: nil)
        end

        def project_batch!(row, snapshot, subscription)
          return unless active?(ExternalSubscription.find_by(id: subscription.id))

          start = row.external_feed_snapshot_id == snapshot.id ? row.position : 0
          finish = [start + Limits::SNAPSHOT_BATCH_ITEMS, snapshot.item_count].min
          return if start >= finish

          items = Parser.parse_positions!(snapshot.body.to_s, (start...finish).to_a)
          resources = items.filter_map { |item| stored_resource(snapshot.external_source, item) }
          missing = resources.reject { |resource| projected?(subscription, resource) }
          return if missing.empty?
          return unless active?(ExternalSubscription.find_by(id: subscription.id))

          Materialize.new.call(subscription: subscription, resources: missing, retries: false)
        end

        def advance_row!(row, token, snapshot)
          start = row.external_feed_snapshot_id == snapshot.id ? row.position : 0
          nxt = [start + Limits::SNAPSHOT_BATCH_ITEMS, snapshot.item_count].min
          done = nxt >= snapshot.item_count
          updated = ExternalFeedCatchUp.where(id: row.id, lease_token: token).update_all(
            external_feed_snapshot_id: snapshot.id,
            position: done ? snapshot.item_count : nxt,
            state: 'pending',
            updated_at: Time.current
          )
          return false unless updated == 1

          done ? bodies(row.external_subscription).where('generation > ?', snapshot.generation).exists? : true
        end

        def stop!(row, token)
          ExternalFeedCatchUp.where(id: row.id, lease_token: token).update_all(state: 'stopped', lease_token: nil, lease_expires_at: nil, updated_at: Time.current)
        end

        def finish!(row, token)
          ExternalFeedCatchUp.where(id: row.id, lease_token: token).update_all(state: 'done', external_feed_snapshot_id: nil, position: 0, lease_token: nil, lease_expires_at: nil, updated_at: Time.current)
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
