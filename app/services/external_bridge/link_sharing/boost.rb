# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Converts "boost this external projection" into a share of the User's own
    # public link note. Only the controller for the projection branch calls
    # this. ReblogService still rejects a projection through
    # ExternalBridge::Guards.reject_target!, and StatusPolicy#reblog? is
    # unchanged.
    #
    # The caller passes the authenticated User. The User is never rebuilt from
    # an Account, an OAuth account id, or Account#user.
    #
    # Order of checks (all fail closed): User and projection marker, feature
    # flag and tester list, the User's functional state, the policy row
    # (enabled, consented, public or unlisted), the requested visibility. Then
    # EnsureReference gets or creates the reference note. A second transaction
    # locks policy, then mapping, then the User's boost rows, re-checks every
    # condition against the locked rows, and only then inserts the wrapper
    # Status and the boost row together. The lock order is the same prefix as
    # EnsureReference, so the two cannot deadlock.
    #
    # Repeating the call returns the live share. A wrapper that was discarded
    # by some other path no longer counts and its row is closed first.
    class Boost
      Result = Struct.new(:boost, :wrapper, :reference, :created, keyword_init: true)

      def self.call(user:, status:, visibility: nil, circle_id: nil)
        new(user, status, visibility, circle_id).call
      end

      def initialize(user, status, visibility, circle_id)
        @user = user
        @status = status
        @requested_visibility = visibility.presence
        @circle_id = circle_id.presence
      end

      def call
        raise Error, :not_owner if @user.nil? || @status.nil?

        projection = ExternalStatusProjection.find_by(status_id: @status.id)
        raise Error, :not_owner if projection.nil?

        Feature.require!(@user)
        Ownership.assert!(@user, projection)
        scope = current_scope!
        reject_widening!(scope)

        ensured = EnsureReference.call(user: @user, projection: projection, scope: scope)
        Checkpoints.fire(:before_boost_lock)
        removals = []
        result = ApplicationRecord.transaction { share!(projection, ensured.mapping, scope, removals) }
        Retire.enqueue_removals(removals)
        BoostSchedule.enqueue!(result.boost.id) if result.created && create_distributed?(result.boost)
        result
      rescue ActiveRecord::RecordNotUnique
        raise Error, :reference_conflict
      end

      private

      # With the Create still pending, the publish worker pushes the Announce
      # once it has written published_at. Pushing earlier would only claim
      # the row for a job that finds nothing to do.
      def create_distributed?(boost)
        ExternalProjectionLinkReference.where(id: boost.link_reference_id).where.not(published_at: nil).exists?
      end

      def current_scope!
        policy = ExternalLinkSharePolicy.find_by(user_id: @user.id)
        raise Error, :consent_required if policy.nil? || !policy.enabled? || policy.consented_at.nil?
        raise Error, :scope_rejected unless EnsureReference::VISIBILITIES.include?(policy.visibility)

        policy.visibility
      end

      # status API parameters never widen or change the consented scope. A
      # value equal to the scope is accepted. Anything else, including
      # mutual, limited, private, direct, and a circle, is refused and does
      # not fall back to a default.
      def reject_widening!(scope)
        raise Error, :circle_rejected if @circle_id
        raise Error, :visibility_mismatch if @requested_visibility && @requested_visibility != scope
      end

      def share!(projection, ensured_mapping, scope, removals)
        policy = ExternalLinkSharePolicy.lock('FOR UPDATE').find_by(user_id: @user.id)
        raise Error, :consent_required if policy.nil? || !policy.enabled? || policy.consented_at.nil?
        raise Error, :policy_changed unless policy.visibility == scope

        mapping = ExternalProjectionLinkReference.lock('FOR UPDATE').find_by(id: ensured_mapping.id)
        raise Error, :reference_broken unless usable_mapping?(mapping, projection, scope)

        reference = Status.find_by(id: mapping.reference_status_id)
        ReferenceIntegrity.verify!(mapping, reference)

        live = lock_live_share(projection, removals)
        return Result.new(boost: live, wrapper: live.wrapper_status, reference: reference, created: false) if live

        Checkpoints.fire(:before_boost_create)
        create_share!(projection, mapping, reference, scope, policy)
      end

      def usable_mapping?(mapping, projection, scope)
        mapping.present? &&
          mapping.active? &&
          mapping.user_id == @user.id &&
          mapping.external_status_projection_id == projection.id &&
          mapping.projection_status_id == projection.status_id &&
          mapping.visibility == scope &&
          mapping.reference_status_id.present?
      end

      # All of this User's active rows for the projection, across references.
      # One is live while its wrapper is a kept Status; the rest are closed.
      def lock_live_share(projection, removals)
        rows = ExternalProjectionLinkBoost.lock('FOR UPDATE')
                                          .where(user_id: @user.id, projection_status_id: projection.status_id, state: 'active')
                                          .order(:id)
                                          .to_a
        live = nil
        rows.each do |row|
          wrapper = Status.find_by(id: row.wrapper_status_id)
          if live.nil? && wrapper.present? && wrapper.account_id == @user.account_id
            live = row
          else
            id = Retire.end!(row, reason: 'wrapper_removed')
            removals << id if id
          end
        end
        live
      end

      def create_share!(projection, mapping, reference, scope, policy)
        generation = ExternalProjectionLinkBoost.where(link_reference_id: mapping.id).maximum(:generation).to_i + 1
        wrapper = create_wrapper!(reference, scope)
        boost = ExternalProjectionLinkBoost.create!(
          user_id: @user.id,
          account_id: @user.account_id,
          link_reference_id: mapping.id,
          external_status_projection_id: projection.id,
          projection_status_id: projection.status_id,
          reference_status_id: reference.id,
          wrapper_status_id: wrapper.id,
          visibility: scope,
          generation: generation,
          policy_revision: policy.revision,
          state: 'active'
        )
        Result.new(boost: boost, wrapper: wrapper, reference: reference, created: true)
      end

      # An ordinary boost of the reference note. Not ReblogService: that path
      # notifies, records trends and tag use, and distributes to feeds, none of
      # which belongs to a share of one's own link note. A kept boost of the
      # same note that this table does not know about is somebody's ordinary
      # boost, and it is not adopted.
      def create_wrapper!(reference, scope)
        if @user.account.statuses.exists?(reblog_of_id: reference.id)
          raise Error, :reference_already_boosted
        end

        @user.account.statuses.create!(reblog: reference, text: '', visibility: scope)
      rescue ActiveRecord::RecordInvalid
        # A discarded boost of the same note that RemovalWorker has not removed
        # yet. Retrying after it has run succeeds.
        raise Error, :reference_conflict
      end
    end
  end
end
