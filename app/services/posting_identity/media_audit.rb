# frozen_string_literal: true

class PostingIdentity::MediaAudit
  # One row per attachment. The insert happens after the file has been
  # stored. It does not copy the description or wrap the storage transfer.
  def self.record!(media:, grantee_user_id:, delegation_id:, posting_account_id:)
    raise ActiveRecord::RecordInvalid, PostingIdentityMedia.new if media.nil? || !media.persisted?

    PostingIdentityMedia.create!(
      media_attachment_id: media.id,
      grantee_user_id: grantee_user_id,
      delegation_id: delegation_id,
      posting_account_id: posting_account_id
    )
  end
end
