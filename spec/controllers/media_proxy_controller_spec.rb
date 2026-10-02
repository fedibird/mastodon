# frozen_string_literal: true

require 'rails_helper'

describe MediaProxyController do # rubocop:disable Metrics/BlockLength
  render_views

  before do
    stub_request(:get, 'http://example.com/attachment.png').to_return(request_fixture('avatar.txt'))
  end

  describe '#show' do # rubocop:disable Metrics/BlockLength
    let(:status) { Fabricate(:status) }
    let(:media_attachment) { Fabricate(:media_attachment, status: status, remote_url: 'http://example.com/attachment.png') }

    def show_variant(any = nil)
      params = { id: media_attachment.id }
      params[:any] = any unless any.nil?
      get :show, params: params
    end

    # The attachment fabricator stores a local file, so a real show would HEAD
    # the asset host to ask whether that file exists. These examples are about
    # variant routing, so treat the file as already cached.
    def stub_cached_media
      allow_any_instance_of(MediaAttachment).to receive(:needs_redownload?).and_return(false)
      allow_any_instance_of(MediaAttachment).to receive(:file_exists?).and_return(true)
      allow_any_instance_of(MediaAttachment).to receive(:needs_reprocess?).and_return(false)
    end

    it 'redirects when attached to a status' do
      stub_cached_media
      show_variant

      expect(response).to have_http_status(302)
    end

    it 'treats /original as the original variant' do
      stub_cached_media
      show_variant('original')

      expect(response).to have_http_status(302)
      expect(response.location).to include('/original/')
    end

    it 'treats /small as the small variant' do
      stub_cached_media
      show_variant('small')

      expect(response).to have_http_status(302)
      expect(response.location).to include('/small/')
    end

    it 'treats /tiny as the tiny variant' do
      stub_cached_media
      show_variant('tiny')

      expect(response).to have_http_status(302)
      expect(response.location).to include('/tiny/')
    end

    it 'treats a missing tail as original' do
      stub_cached_media
      expect(media_proxy_path(media_attachment.id)).to eq("/media_proxy/#{media_attachment.id}")

      show_variant

      expect(response).to have_http_status(302)
      expect(response.location).to include('/original/')
    end

    it 'rejects an arbitrary tail before looking up the attachment' do
      media_attachment
      expect(MediaAttachment).not_to receive(:remote)

      show_variant('garbage')

      expect(response).to have_http_status(404)
      expect(a_request(:get, 'http://example.com/attachment.png')).not_to have_been_made
    end

    it 'rejects a srcset candidate list before downloading or reprocessing' do
      srcset = "original 1024w, https:/cdn.example/image.webp 1024w, https:/fedibird.com/media_proxy/#{media_attachment.id}/small 400w"
      expect(MediaAttachment).not_to receive(:remote)
      expect_any_instance_of(MediaAttachment).not_to receive(:download_file!)

      show_variant(srcset)

      expect(response).to have_http_status(404)
      expect(a_request(:get, 'http://example.com/attachment.png')).not_to have_been_made
    end

    it 'keeps HTTP timeouts on a valid original path as 500' do
      allow_any_instance_of(MediaAttachment).to receive(:needs_redownload?).and_return(true)
      allow_any_instance_of(MediaAttachment).to receive(:download_file!).and_raise(HTTP::TimeoutError)

      show_variant('original')

      expect(response).to have_http_status(500)
    end

    it 'responds with missing when there is not an attached status' do
      media_attachment = Fabricate(:media_attachment, status: nil, remote_url: 'http://example.com/attachment.png')
      get :show, params: { id: media_attachment.id }

      expect(response).to have_http_status(404)
    end

    it 'raises when id cant be found' do
      get :show, params: { id: 'missing' }

      expect(response).to have_http_status(404)
    end

    it 'raises when not permitted to view' do
      status = Fabricate(:status, visibility: :direct)
      media_attachment = Fabricate(:media_attachment, status: status, remote_url: 'http://example.com/attachment.png')
      get :show, params: { id: media_attachment.id }

      expect(response).to have_http_status(404)
    end
  end
end
