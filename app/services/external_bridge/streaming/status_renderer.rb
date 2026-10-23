# frozen_string_literal: true

module ExternalBridge
  module Streaming
    # Renders one status for the marker's user. InlineRenderer recovers
    # current_user from Account#user, which is a different user of the same
    # account. Callers pass the owner and nothing else.
    class StatusRenderer
      def self.render(status, user)
        return nil if status.nil? || user.nil?
        return nil unless owner?(status, user)

        ActiveModelSerializers::SerializableResource.new(
          status,
          serializer: REST::StatusSerializer,
          scope: user,
          scope_name: :current_user
        ).as_json
      end

      def self.owner?(status, user)
        marker = if status.association(:external_status_projection).loaded?
                   status.external_status_projection
                 else
                   ExternalStatusProjection.find_by(status_id: status.id)
                 end
        marker&.user_id == user.id
      end
      private_class_method :owner?
    end
  end
end
