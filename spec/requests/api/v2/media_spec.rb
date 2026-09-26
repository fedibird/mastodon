# frozen_string_literal: true

require 'rails_helper'

def post_v2_media(headers, name, content_type)
  post '/api/v2/media', headers: headers, params: { file: fixture_file_upload(name, content_type) }
end

RSpec.describe 'Media API', paperclip_processing: true do
  let(:user)    { Fabricate(:user) }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:media') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

  describe 'POST /api/v2/media' do
    before do
      allow(PostProcessMediaWorker).to receive(:perform_async)
    end

    context 'with a JPEG' do
      before { post_v2_media(headers, 'attachment.jpg', 'image/jpeg') }

      it 'processes the image synchronously and returns 200' do
        media = user.account.media_attachments.first

        expect(response).to have_http_status(200)
        expect(media).to be_present
        expect(media.type).to eq 'image'
        expect(media.processing_complete?).to be true
        expect(media.not_processed?).to be false
        expect(media.file.exists?(:small)).to be true
        expect(media.file.exists?(:tiny)).to be true
        expect(PostProcessMediaWorker).not_to have_received(:perform_async)
      end
    end

    context 'with an animated GIF' do
      before { post_v2_media(headers, 'avatar.gif', 'image/gif') }

      it 'reclassifies the GIF as gifv, queues it, and returns 202' do
        media = user.account.media_attachments.first

        expect(response).to have_http_status(202)
        expect(media).to be_present
        expect(media.type).to eq 'gifv'
        expect(media.processing_queued?).to be true
        expect(media.not_processed?).to be true
        expect(PostProcessMediaWorker).to have_received(:perform_async).with(media.id)
      end
    end

    context 'with a video' do
      before { post_v2_media(headers, 'attachment.webm', 'video/webm') }

      it 'queues larger media and returns 202' do
        media = user.account.media_attachments.first

        expect(response).to have_http_status(202)
        expect(media).to be_present
        # This WebM has no audio stream, so the existing transcoder stores it as gifv.
        # gifv is still a larger media format and stays queued.
        expect(media.type).to eq 'gifv'
        expect(media.larger_media_format?).to be true
        expect(media.processing_queued?).to be true
        expect(media.not_processed?).to be true
        expect(PostProcessMediaWorker).to have_received(:perform_async).with(media.id)
      end
    end
  end
end
