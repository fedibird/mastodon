# frozen_string_literal: true

class Scheduler::MediaCleanupScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  # Candidates are unattached rows older than a day that no draft names.
  # Each delete locks that media row and checks the reference again, so a
  # draft that links the file after the candidate query does not lose it.
  def perform
    candidates.find_each { |media| reclaim(media.id) }
  end

  private

  def candidates
    MediaAttachment.reorder(nil).unattached.where('created_at < ?', 1.day.ago).where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM post_draft_media_attachments
        WHERE post_draft_media_attachments.media_attachment_id = media_attachments.id
      )
    SQL
  end

  def reclaim(id)
    ApplicationRecord.transaction do
      media = MediaAttachment.lock.find_by(id: id)
      media.destroy! if orphan?(media)
    end
  rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::InvalidForeignKey
    nil
  end

  def orphan?(media)
    return false if media.nil?
    return false if media.status_id.present? || media.scheduled_status_id.present?
    return false if media.created_at >= 1.day.ago
    return false if PostDraftMediaAttachment.exists?(media_attachment_id: media.id)

    true
  end
end
