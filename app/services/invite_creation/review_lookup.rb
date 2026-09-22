# frozen_string_literal: true

# One-query index of invite-creation Action Review rows for the invites
# currently being rendered. Only an approved creation review is a normal
# invite. Pending, rejected, and cancelled shells stay expired; ordinary
# deactivate must not approve them or clear the review.
module InviteCreation
  class ReviewLookup
    def self.for_invites(invites)
      ids = Array(invites).map(&:id).compact
      return {} if ids.empty?

      ActionReviewRequest
        .where(operation_type: 'invite_creation', resource_type: 'Invite', resource_id: ids)
        .order(id: :desc)
        .each_with_object({}) { |request, index| index[request.resource_id] ||= request }
    end

    # A creation review that is not approved keeps the shell unissued.
    # approved_state? is the only release. Cancelled is included because
    # the generic request state already exists.
    def self.held_review?(review)
      review.present? && !review.approved_state?
    end

    # Skipping expire! avoids touching expires_at up to "now", which would
    # make the strict expired? check pass and the code usable. The row used
    # here is the newest creation review, matching for_invites.
    def self.management_expire!(invite)
      return if held_review?(latest_for(invite))

      invite.expire!
    end

    def self.latest_for(invite)
      ActionReviewRequest
        .where(operation_type: 'invite_creation', resource_type: 'Invite', resource_id: invite.id)
        .order(id: :desc)
        .first
    end
    private_class_method :latest_for
  end
end
