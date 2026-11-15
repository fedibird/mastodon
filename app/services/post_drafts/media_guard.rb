# frozen_string_literal: true

module PostDrafts
  class MediaGuard
    def self.referenced?(media_ids)
      ids = normalize(media_ids)
      return false if ids.empty?

      PostDraftMediaAttachment.where(media_attachment_id: ids).exists?
    end

    # Call inside the transaction that is about to set status_id or
    # scheduled_status_id. Rows are locked in ascending id order, which is
    # the same order MediaLinks uses, before the reference is checked again.
    def self.publication_allowed!(media_ids)
      ids = normalize(media_ids)
      return if ids.empty?

      MediaAttachment.where(id: ids).order(:id).lock.load
      return unless referenced?(ids)

      raise Mastodon::ValidationError, I18n.t('media_attachments.validations.retained_by_draft')
    end

    # A completed row can still point at a deleted blob. Both the save and
    # the later read use this check. A storage error is a missing file, so
    # the save rolls back and the read stays partial.
    def self.stored_file?(media)
      media.file.present? && media.file.exists?
    rescue Errno::ENOENT, Paperclip::Error
      false
    end

    def self.normalize(media_ids)
      Array(media_ids).map { |item| item.respond_to?(:id) ? item.id.to_i : item.to_i }.uniq.sort
    end
    private_class_method :normalize
  end
end
