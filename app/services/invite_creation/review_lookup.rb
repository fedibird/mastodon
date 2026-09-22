# frozen_string_literal: true

# One-query index of invite-creation Action Review rows for the invites
# currently being rendered. Pending and rejected shells stay expired;
# ordinary deactivate must not approve them or clear the review.
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

    # Already-expired pending and rejected shells stay expired. Skipping
    # expire! avoids touching expires_at up to "now", which would make
    # the strict expired? check pass and the code usable.
    def self.management_expire!(invite)
      review = ActionReviewRequest.find_by(
        operation_type: 'invite_creation',
        resource_type: 'Invite',
        resource_id: invite.id
      )
      return if review&.pending_state? || review&.rejected_state?

      invite.expire!
    end
  end
end
