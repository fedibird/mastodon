# frozen_string_literal: true

module ExternalBridge
  # allow? is true only when a marker exists and its user_id matches.
  # A true column with no marker is a denial, including for the account holder.
  module ProjectionAccess
    module_function

    def allow?(viewer_user_id, status_or_id)
      return false if viewer_user_id.nil?

      status_id = status_or_id.respond_to?(:id) ? status_or_id.id : status_or_id
      return false if status_id.nil?

      if status_or_id.respond_to?(:association) && status_or_id.association(:external_status_projection).loaded?
        return status_or_id.external_status_projection&.user_id == viewer_user_id
      end

      ExternalStatusProjection.exists?(status_id: status_id, user_id: viewer_user_id)
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
      end

      def private?(status)
        @flagged[status.id] || @markers.key?(status.id)
      end

      def visible?(status)
        return true unless private?(status)
        return false if @viewer_user_id.nil?

        @markers[status.id] == @viewer_user_id
      end
    end
  end
end
