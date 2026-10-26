# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::RSS::Media::VideoTransfer do
  let(:url) { 'https://cdn.example/clip.mp4' }
  let(:limit) { 20.megabytes }

  def candidate(length: nil, mime: 'video/mp4')
    { 'url' => url, 'kind' => 'video', 'mime_hint' => mime, 'length_hint' => length }.compact
  end

  def head(length:, type: 'video/mp4', code: 200)
    ExternalBridge::RSS::Response.new(code: code, content_type: type, content_length: length, final_url: url)
  end

  def body_response(body, type: 'video/mp4')
    ExternalBridge::RSS::Response.new(code: 200, body: body, content_type: type, content_length: body.bytesize, final_url: url)
  end

  around do |example|
    previous_mode = Setting.external_bridge_rss_video_policy
    previous_limit = Setting.external_bridge_rss_video_max_download_mib
    example.run
  ensure
    Setting.external_bridge_rss_video_policy = previous_mode
    Setting.external_bridge_rss_video_max_download_mib = previous_limit
    Rails.cache.clear
  end

  before do
    Setting.external_bridge_rss_video_policy = 'hybrid'
    Setting.external_bridge_rss_video_max_download_mib = 20
    Rails.cache.clear
  end

  it 'keeps the default remote and a 20 MiB cap' do
    Setting.where(var: %w(external_bridge_rss_video_policy external_bridge_rss_video_max_download_mib)).delete_all
    Rails.cache.clear

    expect(ExternalBridge::RSS::Media::Policy.mode).to eq 'remote'
    expect(ExternalBridge::RSS::Media::Policy.max_bytes).to eq 20.megabytes
  end

  it 'does not request a video while the policy is remote' do
    Setting.external_bridge_rss_video_policy = 'remote'
    Rails.cache.clear
    expect(ExternalBridge::RSS::HttpClient).not_to receive(:head)
    expect(ExternalBridge::RSS::HttpClient).not_to receive(:get)

    outcome = described_class.new.call(candidate(length: 10.megabytes))

    expect(outcome.result).to be_nil
    expect(outcome.code).to eq :policy_remote
  end

  it 'stores a known video at the cap and refuses one byte over it' do
    expect(ExternalBridge::RSS::HttpClient).to receive(:head).with(url, hash_including(:profile)).and_return(head(length: limit))
    expect(ExternalBridge::RSS::HttpClient).to receive(:get).and_return(body_response('small-video'))

    stored = described_class.new.call(candidate(length: limit))
    expect(stored.result.body).to eq 'small-video'
    expect(stored.result.content_type).to eq 'video/mp4'

    expect(ExternalBridge::RSS::HttpClient).not_to receive(:head)
    refused = described_class.new.call(candidate(length: limit + 1))
    expect(refused.result).to be_nil
    expect(refused.code).to eq :video_over_cap
    expect(refused.terminal).to be true
  end

  it 'leaves an unknown size remote without a GET' do
    expect(ExternalBridge::RSS::HttpClient).to receive(:head).and_return(head(length: nil))
    expect(ExternalBridge::RSS::HttpClient).not_to receive(:get)

    outcome = described_class.new.call(candidate(length: nil))

    expect(outcome.result).to be_nil
    expect(outcome.code).to eq :video_size_unknown
  end

  it 'does not GET a video whose HEAD is already over the cap' do
    expect(ExternalBridge::RSS::HttpClient).to receive(:head).and_return(head(length: 30.megabytes))
    expect(ExternalBridge::RSS::HttpClient).not_to receive(:get)

    expect(described_class.new.call(candidate(length: 10.megabytes)).code).to eq :video_over_cap
  end

  it 'discards a body that exceeds the cap after a short Content-Length' do
    expect(ExternalBridge::RSS::HttpClient).to receive(:head).and_return(head(length: 10.megabytes))
    expect(ExternalBridge::RSS::HttpClient).to receive(:get).and_raise(ExternalBridge::Error, :media_too_large)

    outcome = described_class.new.call(candidate(length: 10.megabytes))

    expect(outcome.result).to be_nil
    expect(outcome.code).to eq :video_over_cap
    expect(outcome.terminal).to be true
  end

  it 'does not store a downloaded video when the policy is remote again before the save' do
    user = Fabricate(:user)
    enable_external_bridge_rss!(user)
    bundle = external_project_for(user)
    bundle[:resource].update!(
      media_candidates: [{ 'url' => url, 'kind' => 'video', 'mime_hint' => 'video/mp4', 'length_hint' => 12, 'position' => 0 }],
      media_revision: 'media-video'
    )
    outcome = ExternalBridge::RSS::Media::VideoTransfer::Outcome.new(
      result: ExternalBridge::RSS::Media::VideoTransfer::Result.new(body: 'mp4', type: :mp4, content_type: 'video/mp4', fingerprint: 'abc'),
      terminal: false,
      code: nil
    )
    allow_any_instance_of(described_class).to receive(:call).and_return(outcome)
    allow(ExternalBridge::RSS::Media::Policy).to receive(:hybrid?).and_return(true, false)

    ExternalBridge::RSS::Media::Fetch.new.call(bundle[:resource].id, 'media-video', ExternalBridge::RSS::MediaDigest.url_digest(url))

    expect(ExternalMediaAsset.count).to eq 0
    expect(bundle[:status].reload.media_attachments).to be_empty
  end

  it 'reads the policy again when the transfer runs' do
    Setting.external_bridge_rss_video_policy = 'hybrid'
    Rails.cache.clear
    expect(ExternalBridge::RSS::HttpClient).to receive(:head) do
      Setting.external_bridge_rss_video_policy = 'remote'
      Rails.cache.clear
      head(length: 10.megabytes)
    end
    expect(ExternalBridge::RSS::HttpClient).to receive(:get).and_return(body_response('later'))

    described_class.new.call(candidate(length: 10.megabytes))
    Rails.cache.clear
    expect(ExternalBridge::RSS::Media::Policy.hybrid?).to be false
  end
end
