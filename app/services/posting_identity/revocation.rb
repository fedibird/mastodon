# frozen_string_literal: true

class PostingIdentity::Revocation
  def self.call!(actor:, delegation:)
    raise PostingIdentity::Error, :not_found if delegation.nil?
    raise PostingIdentity::Error, :not_owner unless actor && [delegation.grantor_user_id, delegation.grantee_user_id].include?(actor.id)
    raise PostingIdentity::Error, :not_found if delegation.revoked_at.present? || delegation.superseded_at.present?

    delegation.revoke!
    delegation
  end
end
