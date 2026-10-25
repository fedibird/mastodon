# frozen_string_literal: true

module ExternalBridge
  # Physical DELETE. Does not discard, does not call RemoveStatusService,
  # and does not enqueue ActivityPub Delete. SET LOCAL is transaction-scoped
  # so a rolled-back purge keeps the status and the marker.
  class ProjectionPurge
    SETTING_SQL = "SET LOCAL fedibird.projection_status_delete = 'on'"

    def self.purge_status!(status)
      purge_status_ids!([status.id], suppress: true)
    end

    # @return [Integer] projection statuses physically deleted by this call
    def self.purge_status_ids!(status_ids, suppress: false, route_targets: [])
      ids = normalize_ids(status_ids)
      return 0 if ids.empty?

      outcome = purge_ids_in_transaction!(ids, suppress: suppress, route_targets: route_targets)
      finish_purge!(ids, outcome[:removals])
      outcome[:deleted]
    end

    # The database half of a purge: stream-delete capture, E4 retirement, and
    # the physical DELETE under SET LOCAL, inside one (savepoint) transaction.
    # Captures are returned either way. schedule_deletes registers
    # StreamDeleteWorker on the outermost commit (a one-shot purge). The
    # batched unsubscribe passes false and stores the captures itself: an
    # enqueue error must not be the thing that skips cache and search, and a
    # killed worker must still be able to read the destinations back.
    #
    # route_targets are extra delete destinations, for a subscription whose
    # feed routes were already removed by the unsubscribe fence.
    def self.purge_ids_in_transaction!(status_ids, suppress: false, route_targets: [], schedule_deletes: true)
      ids = normalize_ids(status_ids)
      return { removals: [], deleted: 0, captures: [] } if ids.empty?

      removals = []
      deleted = 0
      captures = []
      ActiveRecord::Base.transaction(requires_new: true) do
        captures = capture_stream_deletes(ids, route_targets)
        remember_suppressions!(ids) if suppress
        removals = LinkSharing::Retire.end_for_projections!(ids, reason: 'projection_purged')
        ExternalProjectionLinkBoostState.where(projection_status_id: ids).delete_all
        ActiveRecord::Base.connection.execute(SETTING_SQL)
        deleted = Status.unscoped.where(id: ids).delete_all
        Streaming::Scheduler.schedule_deletes!(captures) if schedule_deletes
      end
      { removals: removals, deleted: deleted, captures: captures }
    ensure
      clear_delete_setting!
    end

    # After the DELETE is durable. Each step stands alone: a Redis or search
    # error must not skip the others. One-shot purges have no outbox for the
    # stream event; schedule_deletes! already swallowed that enqueue error.
    def self.finish_purge!(status_ids, removals)
      ids = normalize_ids(status_ids)
      isolate('wrapper_removal') { LinkSharing::Retire.enqueue_removals(removals) }
      clear_local_copies!(ids)
    end

    # Idempotent. Safe to repeat for the same ids.
    def self.clear_local_copies!(status_ids)
      ids = normalize_ids(status_ids)
      isolate('cache') { ids.each { |id| Rails.cache.delete("statuses/#{id}") } }
      isolate('search') { remove_search_documents(ids) }
    end

    def self.isolate(step)
      yield
    rescue StandardError => e
      Rails.logger.warn("[ExternalBridge] purge side effect step=#{step} error=#{e.class}")
    end
    private_class_method :isolate

    def self.normalize_ids(status_ids)
      Array(status_ids).map(&:to_i).uniq.reject(&:zero?)
    end
    private_class_method :normalize_ids

    def self.purge_user!(user)
      ids = ExternalStatusProjection.where(user_id: user.id).pluck(:status_id)
      purge_status_ids!(ids)
    end

    def self.purge_for_account!(account)
      user_ids = User.where(account_id: account.id).pluck(:id)
      ids = ExternalStatusProjection.where(user_id: user_ids).pluck(:status_id)
      account_ids = ExternalStatusProjection.where(account_id: account.id).pluck(:status_id)
      purge_status_ids!(ids + account_ids)
    end

    def self.purge_subscription!(subscription)
      ids = ExternalStatusProjection.where(external_subscription_id: subscription.id).pluck(:status_id)
      purge_status_ids!(ids)
    end

    def self.capture_stream_deletes(status_ids, route_targets = [])
      markers = ExternalStatusProjection.joins(:status).where(status_id: status_ids).where(
        statuses: { visibility: Status.visibilities[:external], external_projection: true }
      ).to_a
      return [] if markers.empty?

      routes = ExternalFeedRoute.where(
        user_id: markers.map(&:user_id).uniq,
        external_subscription_id: markers.map(&:external_subscription_id).uniq
      ).to_a
      grouped = routes.group_by { |route| [route.user_id, route.external_subscription_id] }
      markers.map { |marker| delete_capture(marker, grouped[[marker.user_id, marker.external_subscription_id]] || [], route_targets) }
    end
    private_class_method :capture_stream_deletes

    def self.delete_capture(marker, routes, route_targets = [])
      destinations = [{ 'type' => 'home' }]
      routes.each do |route|
        next unless route.destination == 'list' && route.list_id.present?

        destinations << { 'type' => 'list', 'id' => route.list_id.to_s }
      end
      Array(route_targets).each do |target|
        next unless target.is_a?(Hash) && target['type'] == 'list' && target['id'].present?

        destinations << { 'type' => 'list', 'id' => target['id'].to_s }
      end
      destinations.uniq!
      {
        'user_id' => marker.user_id.to_s,
        'status_id' => marker.status_id.to_s,
        'subscription_id' => marker.external_subscription_id.to_s,
        'destinations' => destinations,
      }
    end
    private_class_method :delete_capture

    def self.remember_suppressions!(status_ids)
      ExternalStatusProjection.where(status_id: status_ids).find_each do |marker|
        ExternalProjectionFailure.where(user_id: marker.user_id, external_resource_id: marker.external_resource_id).delete_all
        suppression = ExternalProjectionSuppression.find_or_initialize_by(user_id: marker.user_id, external_resource_id: marker.external_resource_id)
        suppression.save!
      end
    end
    private_class_method :remember_suppressions!

    def self.clear_delete_setting!
      connection = ActiveRecord::Base.connection
      return unless connection.transaction_open?

      connection.execute("SET LOCAL fedibird.projection_status_delete = 'off'")
    rescue StandardError
      nil
    end
    private_class_method :clear_delete_setting!

    def self.remove_search_documents(ids)
      return unless Chewy.enabled?

      Chewy.strategy.current.update(StatusesIndex, ids)
    rescue StandardError => e
      Rails.logger.warn("[ExternalBridge] search delete failed: #{e.class}")
    end
    private_class_method :remove_search_documents
  end
end
