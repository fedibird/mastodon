# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'JPEG XL media attachments' do # rubocop:disable Metrics/BlockLength
  let(:account) { Fabricate(:account) }

  describe 'acceptance' do
    it 'advertises .jxl and image/jxl as image input and keeps HEIC/HEIF/AVIF disabled' do
      expect(MediaAttachment::IMAGE_FILE_EXTENSIONS).to include('.jxl')
      expect(MediaAttachment::IMAGE_MIME_TYPES).to include('image/jxl')
      expect(MediaAttachment::IMAGE_CONVERTIBLE_MIME_TYPES).to include('image/bmp', 'image/jxl')
      expect(MediaAttachment.supported_file_extensions).to include('.jxl')
      expect(MediaAttachment.supported_mime_types).to include('image/jxl')

      %w(image/heic image/heif image/avif).each do |mime_type|
        expect(MediaAttachment::IMAGE_MIME_TYPES).not_to include(mime_type)
        expect(MediaAttachment::IMAGE_CONVERTIBLE_MIME_TYPES).not_to include(mime_type)
      end
      expect(MediaAttachment.supported_file_extensions).not_to include('.heic', '.heif', '.avif')
    end

    it 'selects WebP converted styles for image/jxl and leaves JPEG, PNG, and WebP on the normal image styles' do
      jxl_styles = styles_for('image/jxl')

      expect(jxl_styles).to eq(MediaAttachment::IMAGE_CONVERTED_STYLES)
      expect(jxl_styles[:original]).to include(format: 'webp', content_type: 'image/webp')
      expect(jxl_styles[:small]).to include(format: 'webp', content_type: 'image/webp')
      expect(jxl_styles[:tiny]).to include(format: 'webp', content_type: 'image/webp')
      expect(styles_for('image/bmp')).to eq(MediaAttachment::IMAGE_CONVERTED_STYLES)
      expect(styles_for('image/jpeg')).to eq(MediaAttachment::IMAGE_STYLES)
      expect(styles_for('image/png')).to eq(MediaAttachment::IMAGE_STYLES)
      expect(styles_for('image/webp')).to eq(MediaAttachment::IMAGE_STYLES)
    end

    it 'classifies image/jxl as an image under the image size limit' do
      media = MediaAttachment.new(file_content_type: 'image/jxl')
      media.send(:set_type_and_extension)

      expect(media.type).to eq('image')
      expect(media.larger_media_format?).to be false
    end

    it 'allows ImageMagick to read JXL and still denies JXL write plus HEIC/HEIF/AVIF' do
      policy = File.read(Rails.root.join('config/imagemagick/policy.xml'))

      expect(policy).to include('rights="read" pattern="JXL"')
      expect(policy).not_to include('pattern="{PNG,APNG,JPEG,GIF,WEBP,BMP,JXL}"')
      expect(policy).to include('rights="none" pattern="{HEIC,HEIF,AVIF}"')
    end
  end

  describe 'content type detection' do
    let(:path) { Rails.root.join('spec/fixtures/files/attachment.jxl') }

    it 'accepts a JPEG XL file as image/jxl without a Paperclip extension mapping' do
      file = File.open(path)
      detector = Paperclip::MediaTypeSpoofDetector.using(file, 'attachment.jxl', 'image/jxl')

      expect(MIME::Types.type_for('attachment.jxl').map(&:content_type)).to include('image/jxl')
      expect(detector.send(:type_from_file_command).chomp.split(/[:;\s]+/).first).to eq('image/jxl')
      expect(Marcel::MimeType.for(Pathname.new(path), name: 'attachment.jxl')).to eq('application/octet-stream')
      expect(Paperclip::ContentTypeDetector.new(path.to_s).detect).to eq('image/jxl')
      expect(detector).not_to be_spoofed
      expect(Paperclip.options[:content_type_mappings]).not_to have_key(:jxl)
      expect(FastImage.type(path.to_s)).to eq(:jxl)
      expect(FastImage.size(path.to_s)).to eq([8, 8])
    end
  end

  describe 'local upload' do
    it 'normalizes JPEG XL to WebP original, small, and tiny styles' do
      media = MediaAttachment.create!(account: account, file: attachment_fixture('attachment.jxl'))

      expect(media).to be_image
      expect(media.processing).to eq('complete')
      expect(media.file_content_type).to eq('image/webp')
      expect(media.file_file_name).to end_with('.webp')
      expect(media.blurhash).to be_present
      expect(media.thumbhash).to be_present
      expect(media.file.meta['original']).to include('width' => 8, 'height' => 8)

      %i(original small tiny).each do |style|
        stored = media.file.path(style)
        expect(File.extname(stored)).to eq('.webp')
        expect(Paperclip::ContentTypeDetector.new(stored).detect).to eq('image/webp')
      end

      json = serialize_media(media)
      expect(json['type']).to eq('image')
      expect(json['url']).to end_with('.webp')
      expect(json['preview_url']).to include('.webp')
    end

    it 'rejects a malformed JPEG XL through the existing processing error' do
      expect do
        MediaAttachment.create!(account: account, file: attachment_fixture('corrupt.jxl'))
      end.to raise_error(Paperclip::Error)

      expect(MediaAttachment.where(account: account)).to be_empty
    end
  end

  describe 'remote download' do
    let(:body) { File.binread(Rails.root.join('spec/fixtures/files/attachment.jxl')) }

    it 'caches a remote .jxl file as WebP' do
      stub_request(:get, 'https://remote.test/tiny.jxl').to_return(status: 200, body: body, headers: { 'Content-Type' => 'image/jxl' })

      media = MediaAttachment.create!(account: account, remote_url: 'https://remote.test/tiny.jxl')
      media.download_file!
      media.save!

      expect(media).to be_image
      expect(media.file_content_type).to eq('image/webp')
      expect(media.file_file_name).to end_with('.webp')
      expect(Paperclip::ContentTypeDetector.new(media.file.path(:original)).detect).to eq('image/webp')
      expect(media.file.meta['original']).to include('width' => 8, 'height' => 8)
    end

    it 'caches a remote JPEG XL payload whose URL has no extension' do
      stub_request(:get, 'https://remote.test/photo').to_return(status: 200, body: body, headers: { 'Content-Type' => 'image/jxl' })

      media = MediaAttachment.create!(account: account, remote_url: 'https://remote.test/photo')
      media.download_file!
      media.save!

      expect(media.file_content_type).to eq('image/webp')
      expect(media.file_file_name).to end_with('.webp')
    end
  end

  describe 'existing image behavior' do
    it 'still converts BMP to WebP' do
      media = MediaAttachment.create!(account: account, file: attachment_fixture('attachment.bmp'))

      expect(media).to be_image
      expect(media.file_content_type).to eq('image/webp')
      expect(media.file_file_name).to end_with('.webp')
      expect(media.file.meta['original']).to include('width' => 8, 'height' => 8)
    end

    it 'leaves JPEG, PNG, and WebP originals in their own formats' do
      jpeg = MediaAttachment.create!(account: account, file: attachment_fixture('attachment.jpg'))
      png = MediaAttachment.create!(account: account, file: attachment_fixture('emojo.png'))
      webp = MediaAttachment.create!(account: account, file: attachment_fixture('attachment.webp'))

      expect(jpeg.file_content_type).to eq('image/jpeg')
      expect(jpeg.file_file_name).to end_with('.jpg')
      expect(png.file_content_type).to eq('image/png')
      expect(png.file_file_name).to end_with('.png')
      expect(webp.file_content_type).to eq('image/webp')
      expect(webp.file_file_name).to end_with('.webp')
    end
  end

  describe 'advertising' do
    before do
      manifest = Webpacker.instance.manifest
      resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
      allow(manifest).to receive(:lookup!, &resolver)
      allow(manifest).to receive(:lookup, &resolver)
    end

    it 'includes JPEG XL in InitialState accept_content_types' do
      accept_content_types = JSON.parse(
        ActiveModelSerializers::SerializableResource.new(
          InitialStatePresenter.new(settings: {}),
          serializer: InitialStateSerializer
        ).to_json
      ).dig('media_attachments', 'accept_content_types')

      expect(accept_content_types).to include('.jxl', 'image/jxl')
      expect(accept_content_types).not_to include('.heic', '.heif', '.avif', 'image/heic', 'image/heif', 'image/avif')
    end
  end

  def styles_for(content_type)
    attachment = instance_double(Paperclip::Attachment, instance: MediaAttachment.new(file_content_type: content_type))
    MediaAttachment.send(:file_styles, attachment)
  end

  def serialize_media(media)
    Rails.application.routes.default_url_options[:host] = 'example.com'
    JSON.parse(ActiveModelSerializers::SerializableResource.new(media, serializer: REST::MediaAttachmentSerializer).to_json)
  end
end
