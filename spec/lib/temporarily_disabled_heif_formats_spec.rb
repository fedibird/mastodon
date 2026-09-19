# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Temporarily disabled HEIC/HEIF/AVIF' do
  let(:disabled_mime_types) { %w(image/heic image/heif image/avif) }
  let(:disabled_extensions) { %w(.heic .heif .avif) }

  it 'rejects those MIME types and extensions for media attachments' do
    expect(MediaAttachment::IMAGE_MIME_TYPES).not_to include(*disabled_mime_types)
    expect(MediaAttachment::IMAGE_CONVERTIBLE_MIME_TYPES).not_to include(*disabled_mime_types)
    expect(MediaAttachment.supported_mime_types).not_to include(*disabled_mime_types)
    expect(MediaAttachment.supported_file_extensions).not_to include(*disabled_extensions)
  end

  it 'still accepts common image types for media attachments' do
    expect(MediaAttachment::IMAGE_MIME_TYPES).to include('image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/bmp')
  end

  it 'rejects those MIME types for custom emoji, avatars, headers, and node assets' do
    [
      CustomEmoji::IMAGE_MIME_TYPES,
      CustomEmoji::IMAGE_CONVERTIBLE_MIME_TYPES,
      AccountAvatar::IMAGE_MIME_TYPES,
      AccountAvatar::IMAGE_CONVERTIBLE_MIME_TYPES,
      AccountHeader::IMAGE_MIME_TYPES,
      AccountHeader::IMAGE_CONVERTIBLE_MIME_TYPES,
      NodeIcon::IMAGE_MIME_TYPES,
      NodeIcon::IMAGE_CONVERTIBLE_MIME_TYPES,
      NodeThumbnail::IMAGE_MIME_TYPES,
    ].each do |types|
      expect(types).not_to include(*disabled_mime_types)
    end

    expect(CustomEmoji::IMAGE_FILE_EXTENSIONS).not_to include(*disabled_extensions)
  end

  it 'does not allow ImageMagick to read or write HEIC, HEIF, or AVIF' do
    policy = File.read(Rails.root.join('config/imagemagick/policy.xml'))
    allow_line = policy.lines.find { |line| line.include?('read | write') }

    expect(allow_line).to include('JPEG')
    expect(allow_line).to include('PNG')
    expect(allow_line).to include('WEBP')
    expect(allow_line).not_to include('HEIC')
    expect(allow_line).not_to include('HEIF')
    expect(allow_line).not_to include('AVIF')
  end

  it 'does not allow HEIC, HEIF, or AVIF in the Paperclip content type validator' do
    allowed = MediaAttachment.validators.grep(Paperclip::Validators::AttachmentContentTypeValidator).flat_map do |validator|
      Array(validator.options[:content_type])
    end

    expect(allowed).not_to include(*disabled_mime_types)
    expect(allowed).to include('image/jpeg', 'image/png')
  end
end
