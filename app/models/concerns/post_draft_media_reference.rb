# frozen_string_literal: true

module PostDraftMediaReference
  extend ActiveSupport::Concern

  included do
    has_one :post_draft_media_attachment, dependent: :restrict_with_error, inverse_of: :media_attachment
    before_destroy :release_or_keep_post_draft_reference, prepend: true
  end

  private

  # Account deletion may remove the owner's files. Every other destroy,
  # including unused-media cleanup, keeps a file a draft still names.
  # The row lock matches PostDrafts::MediaLinks and MediaGuard.
  def release_or_keep_post_draft_reference
    self.class.where(id: id).order(:id).lock.load
    link = PostDraftMediaAttachment.find_by(media_attachment_id: id)
    return if link.nil?
    # Account deletion sets this before dependent media is destroyed.
    # A direct destroy, including unused-media cleanup, keeps the file.
    if destroyed_by_association
      link.delete
      association(:post_draft_media_attachment).reset
      return
    end

    errors.add(:base, I18n.t('media_attachments.validations.retained_by_draft'))
    throw :abort
  end
end
