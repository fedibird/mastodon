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
    end
  end
end
