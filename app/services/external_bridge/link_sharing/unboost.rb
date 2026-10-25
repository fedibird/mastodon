# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Undo of a share. Needs the projection marker of this User and nothing
    # else: the feature flag, the tester list, and the policy are not read, so
    # turning sharing off or revoking consent never traps a live share.
    #
    # Only this User's rows for the projection are closed. A second User of
    # the same Account has no marker for the projection and gets not_owner.
    # The wrapper is discarded and, if its Announce was already handed to
    # distribution, passed to LinkWrapperRemovalWorker so followers get the Undo. The
    # reference note, the projection, favourites, and bookmarks stay.
    # Repeating the call, or calling it with no share, succeeds and ends
    # nothing.
    class Unboost
      Result = Struct.new(:ended, keyword_init: true)

      def self.call(user:, status:)
        new(user, status).call
      end

      def initialize(user, status)
        @user = user
        @status = status
      end

      def call
        raise Error, :not_owner if @user.nil? || @status.nil?
        raise Error, :not_owner unless ProjectionAccess.allow?(@user.id, @status)

        removals = []
        ended = 0
        ApplicationRecord.transaction do
          ExternalProjectionLinkBoost.lock('FOR UPDATE')
                                     .where(user_id: @user.id, projection_status_id: @status.id, state: 'active')
                                     .order(:id)
                                     .each do |boost|
            ended += 1
            id = Retire.end!(boost, reason: 'user_undo')
            removals << id if id
          end
        end
        Retire.enqueue_removals(removals)
        Result.new(ended: ended)
      end
    end
  end
end
