# frozen_string_literal: true

module ExternalBridge
  # allow? is true only when a marker exists and its user_id matches.
  # A true column with no marker is a denial, including for the account holder.
  module ProjectionAccess
    module_function

    def allow?(viewer_user_id, status_or_id)
      return false if viewer_user_id.nil?

      if status_or_id.respond_to?(:instance_variable_defined?) && status_or_id.instance_variable_defined?(:@external_projection_marker)
        return false unless status_or_id.instance_variable_get(:@external_projection_marker)

        return status_or_id.instance_variable_get(:@external_projection_owner_id) == viewer_user_id
      end

      if status_or_id.respond_to?(:association) && status_or_id.association(:external_status_projection).loaded?
        return status_or_id.external_status_projection&.user_id == viewer_user_id
      end

      status_id = status_or_id.respond_to?(:id) ? status_or_id.id : status_or_id
      return false if status_id.nil?

      ExternalStatusProjection.exists?(status_id: status_id, user_id: viewer_user_id)
    end

    # One indexed read for a page. Later private_status? / allow? calls on
    # these objects do not query again. Statuses that already have the cache
    # are left alone.
    def prepare!(statuses)
      list = Array(statuses).flatten.compact.uniq
      list.select! { |status| status.respond_to?(:id) && status.id.present? && !status.instance_variable_defined?(:@external_projection_marker) }
      return if list.empty?

      loaded, pending = list.partition { |status| status.respond_to?(:association) && status.association(:external_status_projection).loaded? }
      loaded.each do |status|
        projection = status.external_status_projection
        status.instance_variable_set(:@external_projection_marker, projection.present?)
        status.instance_variable_set(:@external_projection_owner_id, projection&.user_id)
      end
      return if pending.empty?

      owners = ExternalStatusProjection.where(status_id: pending.map(&:id)).pluck(:status_id, :user_id).to_h
      remember_markers!(pending, owners)
    end

    def remember_markers!(statuses, owners)
      statuses.each do |status|
        owner = owners[status.id]
        status.instance_variable_set(:@external_projection_marker, !owner.nil?)
        status.instance_variable_set(:@external_projection_owner_id, owner)
      end
    end

    def filter_visible(statuses, viewer_user_id)
      decision = Decision.for(statuses, viewer_user_id)
      statuses.select { |status| decision.visible?(status) }
    end

    class Decision
      def self.for(statuses, viewer_user_id)
        new(statuses, viewer_user_id)
      end

      def initialize(statuses, viewer_user_id)
        @viewer_user_id = viewer_user_id
        ids = Array(statuses).map(&:id)
        @markers = if ids.empty?
                     {}
                   else
                     ExternalStatusProjection.where(status_id: ids).pluck(:status_id, :user_id).to_h
                   end
        @flagged = Array(statuses).each_with_object({}) do |status, memo|
          memo[status.id] = status.external_projection == true
        end
        ProjectionAccess.remember_markers!(Array(statuses).compact, @markers)
      end

      def private?(status)
        ProjectionPrivacy.external_signal?(status) || @flagged[status.id] || @markers.key?(status.id)
      end

      def visible?(status)
        return true unless private?(status)
        return false if @viewer_user_id.nil?

        @markers[status.id] == @viewer_user_id
      end
    end
  end
end
