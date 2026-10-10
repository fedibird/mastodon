# frozen_string_literal: true

class PostingIdentity::PostAudit
  # Called inside the status transaction. A failure rolls the status back
  # with this row. Distribution has not started yet.
  def self.record!(status:, grantee_user_id:, delegation_id:, posting_account_id:)
    raise ActiveRecord::RecordInvalid, PostingIdentityPost.new if status.nil? || !status.persisted?

    PostingIdentityPost.create!(
      status_id: status.id,
      grantee_user_id: grantee_user_id,
      delegation_id: delegation_id,
      posting_account_id: posting_account_id,
      posted_at: status.created_at || Time.current
    )
  end
end
