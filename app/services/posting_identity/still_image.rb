# frozen_string_literal: true

class PostingIdentity::StillImage
  # Delegated uploads follow MediaAttachment's still-image types.
  # The stored type and the bytes are both checked. A renamed video
  # or an animated GIF classified as gifv is not a still image.
  def self.acceptable?(media)
    return false if media.nil?
    return false unless media.image?
    return false if media.gifv? || media.video? || media.audio? || media.unknown?

    content_type = media.file_content_type.to_s
    return false unless MediaAttachment::IMAGE_MIME_TYPES.include?(content_type)

    detected = detected_media_type(media)
    return false if detected.present? && !MediaAttachment::IMAGE_MIME_TYPES.include?(detected)

    true
  end

  def self.detected_media_type(media)
    path = local_file_path(media)
    return nil if path.blank?

    Marcel::MimeType.for(Pathname.new(path), name: File.basename(path.to_s))
  rescue StandardError
    nil
  end

  def self.local_file_path(media)
    file = media.file
    queued = file.respond_to?(:queued_for_write) ? file.queued_for_write[:original] : nil
    queued_path = queued.respond_to?(:path) ? queued.path : nil
    return queued_path if queued_path.present? && File.exist?(queued_path.to_s)

    path = file.respond_to?(:path) ? file.path(:original) : nil
    return path if path.present? && File.exist?(path.to_s)

    nil
  end
  private_class_method :detected_media_type, :local_file_path
end
