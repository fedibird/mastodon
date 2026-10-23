# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # The caller passes the User. Account#user is not a substitute.
    module Ownership
      def self.assert!(user, projection)
        raise Error, :not_owner if user.nil? || projection.nil?
        raise Error, :user_not_functional unless user.functional?
        raise Error, :not_owner unless user.id == projection.user_id
        raise Error, :not_owner unless user.account_id.present? && user.account_id == projection.account_id
        raise Error, :not_owner unless ProjectionAccess.allow?(user.id, projection.status)
      end

      # E4-B only converts the canonical projection: visibility external (201),
      # external_projection true, and a marker whose User, Account, Subscription,
      # Source and Resource agree. A marker on a legacy personal (200) row, or a
      # row that carries only the flag or only the visibility, is refused. E4-A
      # EnsureReference keeps its own contract; Boost and BoostAnnounce are its
      # only callers, and both call this first.
      def self.assert_canonical!(user, projection)
        assert!(user, projection)
        status = projection.status
        raise Error, :projection_not_canonical unless status.present? && status.external_visibility? && status.external_projection == true
        raise Error, :projection_not_canonical unless projection.user_id == user.id && projection.account_id == user.account_id && projection.status_id == status.id

        subscription = ExternalSubscription.find_by(id: projection.external_subscription_id)
        resource = ExternalResource.find_by(id: projection.external_resource_id)
        return if subscription.present? && resource.present? &&
                  subscription.user_id == user.id &&
                  subscription.external_source_id == projection.external_source_id &&
                  resource.external_source_id == projection.external_source_id

        raise Error, :projection_not_canonical
      end
    end
  end
end
