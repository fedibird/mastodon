# frozen_string_literal: true

class PostProcessMediaWorker
  include Sidekiq::Worker

  # `ui` is the media queue: config/sidekiq.yml and Procfile.dev consume it,
  # and Admin::SystemCheck::SidekiqProcessCheck requires a process on it.
  # A dedicated media process must include `-q ui`. Video already uses this
  # worker, so still-image jobs stay here rather than moving queues.
  sidekiq_options queue: 'ui', retry: 1, dead: false

  sidekiq_retries_exhausted do |msg|
    media_attachment_id = msg['args'].first

    ActiveRecord::Base.connection_pool.with_connection do
      begin
        media_attachment = MediaAttachment.find(media_attachment_id)
        media_attachment.processing = :failed
        media_attachment.save
      rescue ActiveRecord::RecordNotFound
        true
      end
    end

    Sidekiq.logger.error("Processing media attachment #{media_attachment_id} failed with #{msg['error_message']}")
  end

  def perform(media_attachment_id)
    media_attachment = MediaAttachment.find(media_attachment_id)
    return true if media_attachment.processing_complete?

    media_attachment.processing = :in_progress
    media_attachment.save

    # Because paperclip-av-transcover overwrites this attribute
    # we will save it here and restore it after reprocess is done
    previous_meta = media_attachment.file_meta || {}

    reprocess_file(media_attachment)
    media_attachment.processing = :complete
    media_attachment.file_meta = previous_meta.merge(media_attachment.file_meta || {}).with_indifferent_access.slice(*MediaAttachment::META_KEYS)
    media_attachment.save
  rescue ActiveRecord::RecordNotFound
    true
  end

  private

  # Still images skip every derivative during upload. Larger media, including
  # an animated GIF reclassified while its thumbnails were written, only
  # deferred :original.
  def reprocess_file(media_attachment)
    if media_attachment.image?
      media_attachment.file.reprocess!
    else
      media_attachment.file.reprocess!(:original)
    end
  end
end
