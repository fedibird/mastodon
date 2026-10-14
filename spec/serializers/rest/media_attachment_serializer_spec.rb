# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::MediaAttachmentSerializer do # rubocop:disable Metrics/BlockLength
  include RoutingHelper

  def serialize(media)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        media,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  it 'returns the medium URL for local media with a shortcode' do
    media = Fabricate(:media_attachment)

    expect(media.local?).to be true
    expect(media.shortcode).to be_present

    json = serialize(media)

    expect(json[:text_url]).to eq(medium_url(media))
    expect(json[:text_url]).to include(media.shortcode)
  end

  it 'returns null instead of an id fallback when a local shortcode is missing' do
    media = Fabricate(:media_attachment)
    media.update_column(:shortcode, nil)
    media.reload

    expect(media.local?).to be true
    expect(media.shortcode).to be_nil
    expect(media.to_param).to eq(media.id.to_s)

    json = serialize(media)

    expect(json).to have_key(:text_url)
    expect(json[:text_url]).to be_nil
  end

  it 'returns null for remote media' do
    media = Fabricate(:media_attachment, remote_url: 'https://remote.example/media/original.jpg')

    expect(media.local?).to be false

    json = serialize(media)

    expect(json).to have_key(:text_url)
    expect(json[:text_url]).to be_nil
  end

  it 'returns null for remote media even when a shortcode is present' do
    media = Fabricate(:media_attachment)
    media.update_column(:remote_url, 'https://remote.example/media/original.jpg')
    media.reload

    expect(media.local?).to be false
    expect(media.shortcode).to be_present

    json = serialize(media)

    expect(json).to have_key(:text_url)
    expect(json[:text_url]).to be_nil
  end

  it 'hides urls while a local upload has not produced a derivative yet' do
    media = Fabricate(:media_attachment)
    media.update_columns(
      processing: MediaAttachment.processings[:queued],
      file_meta: { 'original' => { 'width' => 32, 'height' => 32 } }
    )
    media.reload

    json = serialize(media)

    expect(json[:url]).to be_nil
    expect(json[:preview_url]).to be_nil
  end

  it 'keeps a ready video preview while the original is still processing' do
    media = Fabricate(:media_attachment)
    media.update_columns(
      type: MediaAttachment.types[:video],
      processing: MediaAttachment.processings[:queued],
      file_meta: {
        'original' => { 'width' => 32, 'height' => 32 },
        'small' => { 'width' => 16, 'height' => 16 },
      }
    )
    media.reload

    json = serialize(media)

    expect(media.not_processed?).to be true
    expect(json[:url]).to be_nil
    expect(json[:preview_url]).to be_present
    expect(json[:preview_url]).not_to include('media_proxy')
  end

  it 'sends a remote attachment that still needs a derivative through the media proxy' do
    media = Fabricate(:media_attachment, remote_url: 'https://remote.example/media/original.jpg')
    media.update_columns(file_meta: { 'original' => { 'width' => 32, 'height' => 32 } })
    media.reload

    json = serialize(media)

    expect(media.local?).to be false
    expect(json[:preview_url]).to include('media_proxy')
  end
end
