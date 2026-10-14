# frozen_string_literal: true

require 'rails_helper'

def post_v2_media(headers, name, content_type, extra = {})
  post '/api/v2/media', headers: headers, params: extra.merge(file: fixture_file_upload(name, content_type))
end

RSpec.describe 'Media API', paperclip_processing: true do # rubocop:disable Metrics/BlockLength
  let(:user)    { Fabricate(:user) }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:media') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

  def capture_heavy_commands
    commands = []
    allow(Paperclip).to receive(:run).and_wrap_original do |method, cmd, arguments = '', *rest|
      commands << [cmd.to_s, arguments.to_s] if cmd.to_s.match?(/convert|identify|ffmpeg/)
      method.call(cmd, arguments, *rest)
    end
    commands
  end

  describe 'POST /api/v2/media' do # rubocop:disable Metrics/BlockLength
    before do
      allow(PostProcessMediaWorker).to receive(:perform_async)
    end

    context 'with a JPEG' do
      it 'queues the upload without image conversion and finishes in the worker' do
        commands = capture_heavy_commands

        post_v2_media(headers, 'attachment.jpg', 'image/jpeg', focus: '0.10,-0.20')

        media = user.account.media_attachments.first

        expect(response).to have_http_status(202)
        expect(media).to be_present
        expect(media.type).to eq 'image'
        expect(media.file_content_type).to eq 'image/jpeg'
        expect(media).to be_processing_queued
        expect(media.not_processed?).to be true
        expect(commands).to eq []
        expect(media.file.exists?(:original)).to be true
        expect(media.file.exists?(:small)).to be false
        expect(media.file.exists?(:tiny)).to be false
        expect(media.blurhash).to be_nil
        expect(PostProcessMediaWorker).to have_received(:perform_async).with(media.id).once
        expect(body_as_json[:url]).to be_nil
        expect(body_as_json[:preview_url]).to be_nil

        get "/api/v1/media/#{media.id}", headers: headers

        expect(response).to have_http_status(206)
        expect(body_as_json[:url]).to be_nil
        expect(body_as_json[:preview_url]).to be_nil

        PostProcessMediaWorker.new.perform(media.id)
        media.reload

        expect(media).to be_processing_complete
        expect(media).to be_image
        expect(media.file_content_type).to eq 'image/jpeg'
        expect(media.file.exists?(:small)).to be true
        expect(media.file.exists?(:tiny)).to be true
        expect(media.blurhash).to be_present
        expect(media.thumbhash).to be_present
        expect(media.focus).to eq '0.1,-0.2'
        expect(media.file_meta).to include('small', 'tiny', 'original')

        get "/api/v1/media/#{media.id}", headers: headers

        expect(response).to have_http_status(200)
        expect(body_as_json[:url]).to be_present
        expect(body_as_json[:preview_url]).to be_present
        expect(body_as_json[:blurhash]).to eq media.blurhash
        expect(body_as_json[:thumbhash]).to eq media.thumbhash
      end
    end

    context 'with a PNG' do
      it 'queues the upload and writes derivatives in the worker' do
        commands = capture_heavy_commands

        post_v2_media(headers, 'emojo.png', 'image/png')

        media = user.account.media_attachments.first

        expect(response).to have_http_status(202)
        expect(media.type).to eq 'image'
        expect(media).to be_processing_queued
        expect(commands).to eq []
        expect(PostProcessMediaWorker).to have_received(:perform_async).with(media.id).once

        PostProcessMediaWorker.new.perform(media.id)

        expect(media.reload).to be_processing_complete
        expect(media.file_content_type).to eq 'image/png'
        expect(media.file.exists?(:small)).to be true
        expect(media.file.exists?(:tiny)).to be true
        expect(media.blurhash).to be_present
      end
    end

    context 'with converted still images' do
      it 'queues BMP and WebP, then finishes them in the worker' do
        commands = capture_heavy_commands

        [
          ['attachment.bmp', 'image/bmp'],
          ['attachment.webp', 'image/webp'],
        ].each do |name, content_type|
          commands.clear

          post_v2_media(headers, name, content_type)

          media = user.account.media_attachments.order(:id).last

          expect(response).to have_http_status(202)
          expect(media.type).to eq 'image'
          expect(media).to be_processing_queued
          expect(commands).to eq []

          PostProcessMediaWorker.new.perform(media.id)
          media.reload

          expect(media).to be_processing_complete
          expect(media).to be_image
          expect(media.file_content_type).to eq 'image/webp'
          expect(media.file.exists?(:small)).to be true
          expect(media.blurhash).to be_present
        end
      end
    end

    context 'with a JPEG XL' do
      it 'queues the upload without decoding it during the request' do
        commands = capture_heavy_commands

        post_v2_media(headers, 'attachment.jxl', 'image/jxl')

        media = user.account.media_attachments.first

        expect(response).to have_http_status(202)
        expect(media.type).to eq 'image'
        expect(media.file_content_type).to eq 'image/jxl'
        expect(media).to be_processing_queued
        expect(commands).to eq []
        expect(PostProcessMediaWorker).to have_received(:perform_async).with(media.id).once
      end
    end

    context 'with a static GIF' do
      it 'queues the still image and leaves it as an image after the worker' do
        commands = capture_heavy_commands

        post_v2_media(headers, 'mini-static.gif', 'image/gif')

        media = user.account.media_attachments.first

        expect(response).to have_http_status(202)
        expect(media.type).to eq 'image'
        expect(media).to be_processing_queued
        expect(commands).to eq []

        PostProcessMediaWorker.new.perform(media.id)

        expect(media.reload).to be_processing_complete
        expect(media.type).to eq 'image'
        expect(media.file_content_type).to eq 'image/gif'
      end
    end

    context 'with several images in succession' do
      it 'accepts each JPEG before thumbnail generation' do
        commands = capture_heavy_commands

        3.times { post_v2_media(headers, 'attachment.jpg', 'image/jpeg') }

        medias = user.account.media_attachments.order(:id)

        expect(medias.size).to eq 3
        expect(commands).to eq []
        medias.each do |media|
          expect(media).to be_processing_queued
          expect(media.file.exists?(:small)).to be false
          expect(PostProcessMediaWorker).to have_received(:perform_async).with(media.id).once
        end
      end
    end

    context 'with a large JPEG' do
      it 'stores the source and returns 202 without running ImageMagick styles' do
        path = Rails.root.join('tmp/large-v2-upload.jpg')
        source = Rails.root.join('spec/fixtures/files/attachment.jpg')
        source_bytes = File.binread(source)
        comment = "\xFF\xFE".b + [65_535].pack('n') + ('A'.b * 65_533)
        File.binwrite(path, source_bytes.byteslice(0, 2) + (comment * 16) + source_bytes.byteslice(2, source_bytes.bytesize - 2))
        uploaded = Rack::Test::UploadedFile.new(path.to_s, 'image/jpeg')
        commands = capture_heavy_commands

        post '/api/v2/media', headers: headers, params: { file: uploaded }

        media = user.account.media_attachments.first

        expect(response).to have_http_status(202)
        expect(media).to be_processing_queued
        expect(media.file_file_size).to be > File.size(source)
        expect(commands).to eq []
        expect(media.file.exists?(:original)).to be true
        expect(media.file.exists?(:small)).to be false
        expect(PostProcessMediaWorker).to have_received(:perform_async).with(media.id).once
      ensure
        FileUtils.rm_f(path)
      end
    end

    context 'with an animated GIF' do
      it 'writes thumbnails, reclassifies as gifv, and defers the original' do
        post_v2_media(headers, 'avatar.gif', 'image/gif')

        media = user.account.media_attachments.first

        expect(response).to have_http_status(202)
        expect(media).to be_present
        expect(media.type).to eq 'gifv'
        expect(media).to be_processing_queued
        expect(media.not_processed?).to be true
        expect(media.file_content_type).to eq 'image/gif'
        expect(media.file_file_name).not_to end_with('.mp4')
        expect(media.file.exists?(:small)).to be true
        expect(PostProcessMediaWorker).to have_received(:perform_async).with(media.id).once

        PostProcessMediaWorker.new.perform(media.id)
        media.reload

        expect(media).to be_processing_complete
        expect(media.type).to eq 'gifv'
        expect(media.file_content_type).to eq 'video/mp4'
        expect(media.file_file_name).to end_with('.mp4')

        get "/api/v1/media/#{media.id}", headers: headers

        expect(response).to have_http_status(200)
        expect(body_as_json[:url]).to be_present
      end
    end

    context 'with a video' do
      it 'queues the original, keeps synchronous thumbnails, and returns 202' do
        post_v2_media(headers, 'attachment.webm', 'video/webm')

        media = user.account.media_attachments.first

        expect(response).to have_http_status(202)
        expect(media).to be_present
        # This WebM has no audio stream, so the thumbnail transcoder stores it as gifv.
        expect(media.type).to eq 'gifv'
        expect(media.larger_media_format?).to be true
        expect(media).to be_processing_queued
        expect(media.not_processed?).to be true
        expect(media.file_content_type).to eq 'video/webm'
        expect(media.file_file_name).not_to end_with('.mp4')
        expect(media.file.exists?(:small)).to be true
        expect(PostProcessMediaWorker).to have_received(:perform_async).with(media.id).once
        expect(body_as_json[:url]).to be_nil
        expect(body_as_json[:preview_url]).to be_present
      end
    end

    context 'with audio' do
      it 'queues the original without transcoding it during the request' do
        commands = capture_heavy_commands

        post_v2_media(headers, 'boop.mp3', 'audio/mpeg')

        media = user.account.media_attachments.first

        expect(response).to have_http_status(202)
        expect(media.type).to eq 'audio'
        expect(media).to be_processing_queued
        expect(commands).to eq []
        expect(PostProcessMediaWorker).to have_received(:perform_async).with(media.id).once
      end
    end

    context 'when processing fails' do
      it 'persists the failed state after retries are exhausted and polling returns 422' do
        post_v2_media(headers, 'attachment.jpg', 'image/jpeg')

        media = user.account.media_attachments.first
        expect(media).to be_processing_queued

        allow_any_instance_of(Paperclip::Attachment).to receive(:reprocess!).and_raise(Paperclip::Error, 'convert failed')

        expect { PostProcessMediaWorker.new.perform(media.id) }.to raise_error(Paperclip::Error, 'convert failed')
        expect(media.reload).to be_processing_in_progress

        expect { PostProcessMediaWorker.new.perform(media.id) }.to raise_error(Paperclip::Error, 'convert failed')
        expect(media.reload).to be_processing_in_progress

        PostProcessMediaWorker.sidekiq_retries_exhausted_block.call({ 'args' => [media.id], 'error_message' => 'convert failed' })

        expect(media.reload).to be_processing_failed

        get "/api/v1/media/#{media.id}", headers: headers

        expect(response).to have_http_status(422)
        expect(body_as_json[:error]).to eq 'Error processing thumbnail for uploaded media'
      end
    end
  end

  describe 'POST /api/v1/media' do
    before do
      allow(PostProcessMediaWorker).to receive(:perform_async)
    end

    it 'processes a JPEG synchronously and returns 200' do
      post '/api/v1/media', headers: headers, params: { file: fixture_file_upload('attachment.jpg', 'image/jpeg') }

      media = user.account.media_attachments.first

      expect(response).to have_http_status(200)
      expect(media.type).to eq 'image'
      expect(media).to be_processing_complete
      expect(media.not_processed?).to be false
      expect(media.file.exists?(:small)).to be true
      expect(media.file.exists?(:tiny)).to be true
      expect(media.blurhash).to be_present
      expect(PostProcessMediaWorker).not_to have_received(:perform_async)
    end
  end
end
