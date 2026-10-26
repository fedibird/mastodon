# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::RSS::Media::Fetch do
  let(:user) { Fabricate(:user) }
  let(:png) { Rails.root.join('spec', 'fixtures', 'files', 'emojo.png').binread }
  let(:bundle) { external_project_for(user) }

  def image_result
    ExternalBridge::RSS::Media::ImageFetch::Result.new(
      body: png,
      type: :png,
      content_type: 'image/png',
      width: 16,
      height: 16,
      fingerprint: Digest::SHA256.hexdigest(png)
    )
  end

  def candidate(url)
    { 'url' => url, 'kind' => 'image', 'role' => 'attachment', 'origin' => 'html_img', 'position' => 0 }
  end

  before do
    enable_external_bridge_rss!(user)
    allow_any_instance_of(described_class).to receive(:attach_all)
  end

  it 'does not record a rate limit as a permanent image failure' do
    url = 'https://cdn.example/wait.png'
    bundle[:resource].update!(media_candidates: [candidate(url)], media_revision: 'rev-wait')
    allow_any_instance_of(described_class).to receive(:with_inflight).and_raise(ExternalBridge::Error, :rate_limited)

    expect do
      described_class.new.call(bundle[:resource].id, 'rev-wait', ExternalBridge::RSS::MediaDigest.url_digest(url))
    end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'rate_limited' }
    expect(ExternalMediaAsset.where(state: 'failed')).to be_empty
    expect { ExternalBridge::RSS::MediaFetchWorker.new.perform(bundle[:resource].id, 'rev-wait', ExternalBridge::RSS::MediaDigest.url_digest(url)) }.to raise_error(ExternalBridge::Error)
  end

  it 'fetches every image when more than the inflight cap run together' do
    stub_const('ExternalBridge::RSS::Limits::MEDIA_INFLIGHT', 1)
    urls = (1..5).map { |number| "https://cdn.example/together-#{number}.png" }
    bundle[:resource].update!(
      media_candidates: urls.each_with_index.map { |url, index| candidate(url).merge('position' => index) },
      media_revision: 'rev-together'
    )
    allow_any_instance_of(ExternalBridge::RSS::Media::ImageFetch).to receive(:call) do
      sleep 0.05
      image_result
    end

    threads = urls.map do |url|
      Thread.new do
        described_class.new.call(bundle[:resource].id, 'rev-together', ExternalBridge::RSS::MediaDigest.url_digest(url))
        :ok
      rescue StandardError => e
        e
      end
    end
    expect(threads.map(&:value)).to all(eq(:ok))
    expect(ExternalMediaAsset.where(state: 'ready').count).to eq 5
    expect(ExternalMediaAsset.where(state: 'failed')).to be_empty
  end

  it 'downloads one shared URL once when two resources ask together' do
    url = 'https://cdn.example/shared.png'
    digest = ExternalBridge::RSS::MediaDigest.url_digest(url)
    other = external_project_for(Fabricate(:user).tap { |person| enable_external_bridge_rss!(person) })
    [bundle, other].each do |item|
      item[:resource].update!(media_candidates: [candidate(url)], media_revision: 'rev-shared')
    end
    calls = 0
    call_lock = Mutex.new
    allow_any_instance_of(ExternalBridge::RSS::Media::ImageFetch).to receive(:call) do
      call_lock.synchronize { calls += 1 }
      sleep 0.1
      image_result
    end

    threads = [bundle, other].map do |item|
      Thread.new { described_class.new.call(item[:resource].id, 'rev-shared', digest) }
    end
    threads.each(&:join)

    expect(calls).to eq 1
    expect(ExternalMediaAsset.where(url_digest: digest, state: 'ready').count).to eq 1
  end
end
