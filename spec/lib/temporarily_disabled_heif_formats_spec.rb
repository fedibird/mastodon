# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Temporarily disabled HEIC/HEIF/AVIF' do
  let(:disabled_mime_types) { %w(image/heic image/heif image/avif) }
  let(:disabled_extensions) { %w(.heic .heif .avif) }
  let(:enabled_image_mime_types) { %w(image/jpeg image/png image/gif image/webp image/bmp) }

  it 'rejects those MIME types and extensions for media attachments' do
    expect(MediaAttachment::IMAGE_MIME_TYPES).not_to include(*disabled_mime_types)
    expect(MediaAttachment::IMAGE_CONVERTIBLE_MIME_TYPES).not_to include(*disabled_mime_types)
    expect(MediaAttachment.supported_mime_types).not_to include(*disabled_mime_types)
    expect(MediaAttachment.supported_file_extensions).not_to include(*disabled_extensions)
  end

  it 'still accepts common image types for media attachments' do
    expect(MediaAttachment::IMAGE_MIME_TYPES).to include(*enabled_image_mime_types)
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

  describe 'ImageMagick policy' do
    let(:policy) { File.read(Rails.root.join('config/imagemagick/policy.xml')) }
    let(:policy_lines) { policy.lines.map(&:strip) }
    let(:allow_line) { policy_lines.find { |line| line.include?('read | write') } }
    let(:explicit_deny_line) { policy_lines.find { |line| line.include?('rights="none"') && line.include?('{HEIC,HEIF,AVIF}') } }

    it 'keeps HEIC, HEIF, and AVIF off the safe allowlist' do
      expect(allow_line).to include('JPEG')
      expect(allow_line).to include('PNG')
      expect(allow_line).to include('WEBP')
      expect(allow_line).to include('BMP')
      expect(allow_line).not_to include('HEIC')
      expect(allow_line).not_to include('HEIF')
      expect(allow_line).not_to include('AVIF')
    end

    it 'explicitly denies HEIC, HEIF, and AVIF after the allow rules' do
      expect(explicit_deny_line).to be_present
      expect(policy_lines.index(explicit_deny_line)).to be > policy_lines.index(allow_line)
    end
  end

  it 'does not allow HEIC, HEIF, or AVIF in the Paperclip content type validator' do
    allowed = MediaAttachment.validators.grep(Paperclip::Validators::AttachmentContentTypeValidator).flat_map do |validator|
      Array(validator.options[:content_type])
    end

    expect(allowed).not_to include(*disabled_mime_types)
    expect(allowed).to include('image/jpeg', 'image/png')
  end

  describe 'advertising surfaces' do
    before do
      stub_webpacker_manifest
    end

    it 'does not advertise HEIC, HEIF, or AVIF from REST::InstanceSerializer' do
      mime_types = serialize(InstancePresenter.new, REST::InstanceSerializer)
        .dig('configuration', 'media_attachments', 'supported_mime_types')

      expect(mime_types).not_to include(*disabled_mime_types)
      expect(mime_types).to include(*enabled_image_mime_types)
    end

    it 'does not advertise HEIC, HEIF, or AVIF from REST::V1::InstanceSerializer' do
      mime_types = serialize(InstancePresenter.new, REST::V1::InstanceSerializer)
        .dig('configuration', 'media_attachments', 'supported_mime_types')

      expect(mime_types).not_to include(*disabled_mime_types)
      expect(mime_types).to include(*enabled_image_mime_types)
    end

    it 'does not put HEIC, HEIF, or AVIF types or extensions in InitialStateSerializer accept_content_types' do
      accept_content_types = serialize(
        InitialStatePresenter.new(settings: {}),
        InitialStateSerializer
      ).dig('media_attachments', 'accept_content_types')

      expect(accept_content_types).not_to include(*disabled_mime_types, *disabled_extensions)
      expect(accept_content_types).to include(*enabled_image_mime_types)
    end
  end

  def serialize(record, serializer)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(record, serializer: serializer).to_json
    )
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
