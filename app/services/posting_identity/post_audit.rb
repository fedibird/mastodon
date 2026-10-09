# frozen_string_literal: true

class PostingIdentity::PostAudit
  # One row per status. A retried idempotent post finds the status again
  # and fills this row if the first attempt saved the status and then failed
  # here. Distribution stays outside this write.
  def self.record!(resolution:, grantee:, status:)
    return unless resolution&.delegated?
    return unless status.is_a?(Status) && status.persisted?

    PostingIdentityPost.find_or_create_by!(status_id: status.id) do |record|
      record.grantee_user = grantee
      record.delegation = resolution.delegation
      record.posting_account = resolution.account
      record.posted_at = status.created_at || Time.current
    end
  rescue ActiveRecord::RecordNotUnique
    PostingIdentityPost.find_by!(status_id: status.id)
  end
end
