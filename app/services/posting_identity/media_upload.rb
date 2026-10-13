# frozen_string_literal: true

class PostingIdentity::MediaUpload
  # The attachment is saved as the posting account before the audit row.
  # Paperclip's storage transfer stays outside the audit insert. A failed
  # audit or a rejected type removes that new row so it cannot be attached.
  def self.create!(resolution:, grantee:, attributes:)
    media = resolution.account.media_attachments.create!(attributes)
    return media unless resolution.delegated?

    accept_delegated!(media, resolution, grantee)
    media
  end

  def self.accept_delegated!(media, resolution, grantee)
    unless PostingIdentity::StillImage.acceptable?(media)
      discard_media(media)
      raise Mastodon::ValidationError, I18n.t('posting_identity_links.delegated_media_type')
    end

    PostingIdentity::MediaAudit.record!(
      media: media,
      grantee_user_id: grantee.id,
      delegation_id: resolution.delegation.id,
      posting_account_id: resolution.account.id
    )
  rescue Mastodon::ValidationError
    raise
  rescue StandardError
    discard_media(media)
    raise
  end
  private_class_method :accept_delegated!

  def self.discard_media(media)
    return if media.nil? || !media.persisted?
    return if PostingIdentityMedia.exists?(media_attachment_id: media.id)

    media.destroy
  rescue StandardError => e
    Rails.logger.error("Delegated media cleanup failed id=#{media.id}: #{e.class}: #{e.message}")
  end
  private_class_method :discard_media
end
