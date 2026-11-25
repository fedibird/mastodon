# frozen_string_literal: true

module PostDraftMediaReference
  extend ActiveSupport::Concern

  included do
    has_one :post_draft_media_attachment, dependent: :restrict_with_error, inverse_of: :media_attachment
    before_destroy :release_or_keep_post_draft_reference, prepend: true
  end

  private

  # DeleteAccountService removes this account's drafts before deleting
  # media. A direct destroy, including unused-media cleanup, keeps a file
  # any draft still names. The row lock matches PostDrafts::MediaLinks.
  def release_or_keep_post_draft_reference
    self.class.where(id: id).order(:id).lock.load
    link = PostDraftMediaAttachment.find_by(media_attachment_id: id)
    return if link.nil?

    # Account#media_attachments dependent destroy sets this. Release a
    # reference owned by this same account. Another account's draft keeps
    # the file, and a direct destroy keeps it as well.
    if destroyed_by_association && own_draft_reference?(link)
      link.delete
      association(:post_draft_media_attachment).reset
      return
    end

    errors.add(:base, I18n.t('media_attachments.validations.retained_by_draft'))
    throw :abort
  end

  def own_draft_reference?(link)
    account_id.present? && PostDraft.where(id: link.post_draft_id, account_id: account_id).exists?
  end
end
