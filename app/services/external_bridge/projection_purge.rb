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

    # The database half of a purge: stream-delete capture, E4 retirement, the
    # physical DELETE under SET LOCAL, and the delete events, all inside one
    # (savepoint) transaction. A caller that keeps its own counters in the same
    # transaction (the batched unsubscribe) must hand the result to
    # finish_purge! after that outer transaction commits. Wrapper removals,
    # cache, and search entries are never touched before the DELETE is durable.
    #
    # route_targets are extra delete destinations, for a subscription whose
    # feed routes were already removed by the unsubscribe fence.
    def self.purge_ids_in_transaction!(status_ids, suppress: false, route_targets: [])
      ids = normalize_ids(status_ids)
      return { removals: [], deleted: 0 } if ids.empty?

      removals = []
      deleted = 0
      ActiveRecord::Base.transaction(requires_new: true) do
        captures = capture_stream_deletes(ids, route_targets)
        remember_suppressions!(ids) if suppress
        removals = LinkSharing::Retire.end_for_projections!(ids, reason: 'projection_purged')
        ExternalProjectionLinkBoostState.where(projection_status_id: ids).delete_all
        ActiveRecord::Base.connection.execute(SETTING_SQL)
        deleted = Status.unscoped.where(id: ids).delete_all
        Streaming::Scheduler.schedule_deletes!(captures)
      end
      { removals: removals, deleted: deleted }
    ensure
      clear_delete_setting!
    end

    def self.finish_purge!(status_ids, removals)
      ids = normalize_ids(status_ids)
      LinkSharing::Retire.enqueue_removals(removals)

      ids.each { |id| Rails.cache.delete("statuses/#{id}") }
      remove_search_documents(ids)
    end

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
