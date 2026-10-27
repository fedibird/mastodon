# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'External RSS image candidate fallback' do
  let(:user) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/fallback.xml' }
  let(:webp_url) { 'https://cdn.example/a.webp' }
  let(:png_url) { 'https://cdn.example/a.png' }
  let(:png) { Rails.root.join('spec', 'fixtures', 'files', 'emojo.png').binread }

  before do
    enable_external_bridge_rss!(user)
    redis.del('external_bridge:rss_media:host:cdn.example')
  end

  it 'attaches the next image after a 404 and does not attach twice' do
    stub_feed(webp: { status: 404, body: '', headers: { 'Content-Type' => 'text/plain' } }, png: png_response('"png-1"'))

    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

    resource = ExternalResource.find_by!(title: 'Story')
    expect(resource.media_candidates.first['url']).to eq webp_url
    expect(resource.media_candidates.first['fallbacks']).to eq [png_url]
    expect(resource.media_revision).to eq ExternalBridge::RSS::MediaDigest.hexdigest(resource.media_candidates)
    status = Status.find(ExternalStatusProjection.find_by!(user_id: user.id).status_id)
    expect(status.media_attachments.count).to eq 1
    expect(status.media_attachments.first.file_content_type).to eq 'image/png'
    expect(status.media_attachments.first.description).to eq 'Story'
    expect(ExternalMediaAsset.find_by(url_digest: digest(png_url))).to be_ready
    rejected = ExternalMediaAsset.find_by!(url_digest: digest(webp_url))
    expect(rejected.failure_code).to eq 'alternate_selected'
    expect(rejected.file_file_name).to be_nil
    sequence = ExternalBridge::RSS::Media::Sequence.for(ExternalStatusProjection.find_by!(user_id: user.id))
    expect(sequence.size).to eq 1
    expect(sequence.first[:delivery]).to eq 'local'

    ExternalBridge::RSS::Media::Sync.enqueue!(resource)
    expect(a_request(:get, webp_url)).to have_been_made.once
    expect(a_request(:get, png_url)).to have_been_made.once
  end

  it 'tries the next URL when the first body is not an image' do
    stub_feed(
      webp: { status: 200, body: 'not-an-image', headers: { 'Content-Type' => 'image/webp' } },
      png: png_response
    )

    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

    expect(ExternalMediaAsset.ready.find_by(url_digest: digest(png_url))).to be_present
    expect(a_request(:get, webp_url)).to have_been_made.once
    expect(a_request(:get, png_url)).to have_been_made.once
  end

  it 'tries the next URL after a timeout and records a 404 when every URL fails' do
    stub_feed(webp: { status: 404, body: '' }, png: { status: 404, body: '' })
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    expect(ExternalMediaAsset.find_by!(url_digest: digest(webp_url)).failure_code).to eq 'http_404'
    expect(Status.find(ExternalStatusProjection.find_by!(user_id: user.id).status_id).media_attachments).to be_empty

    resource = ExternalResource.find_by!(title: 'Story')
    ExternalMediaAsset.where(url_digest: digest(webp_url)).delete_all
    WebMock.reset_executed_requests!
    stub_request(:get, webp_url).to_timeout
    stub_request(:get, png_url).to_return(png_response)
    ExternalBridge::RSS::Media::Fetch.new.call(resource.id, resource.media_revision, digest(webp_url))

    expect(ExternalMediaAsset.ready.find_by(url_digest: digest(png_url))).to be_present
    expect(a_request(:get, png_url)).to have_been_made.once
  end

  it 'does not request an unsafe fallback or a URL past the attempt cap' do
    urls = (1..6).map { |number| "https://cdn.example/n#{number}.png" }
    candidate = { 'url' => 'http://127.0.0.1/secret.png', 'kind' => 'image', 'fallbacks' => urls + ['javascript:alert(1)'] }
    expect(ExternalBridge::RSS::Media::ImageAttempts.urls(candidate)).to eq urls.first(ExternalBridge::RSS::Limits::MAX_IMAGE_FETCH_ATTEMPTS)
    expect(ExternalBridge::RSS::Limits::MAX_IMAGE_FETCH_ATTEMPTS).to eq ExternalBridge::RSS::Limits::MAX_IMAGE_FALLBACKS + 1

    resource = publish_candidate(candidate.merge('url' => urls.first, 'fallbacks' => urls.drop(1)))
    urls.each { |url| stub_request(:get, url).to_return(status: 404, body: '') }
    ExternalBridge::RSS::Media::Fetch.new.call(resource.id, resource.media_revision, digest(urls.first))

    expect(a_request(:get, urls[4])).to have_been_made.once
    expect(a_request(:get, urls[5])).not_to have_been_made
    expect(a_request(:get, 'http://127.0.0.1/secret.png')).not_to have_been_made
  end

  it 'stops on the host budget before the next candidate' do
    resource = publish_candidate('url' => webp_url, 'kind' => 'image', 'fallbacks' => [png_url], 'description' => 'Story')
    calls = []
    fetcher = instance_double(ExternalBridge::RSS::Media::ImageFetch)
    allow(ExternalBridge::RSS::Media::ImageFetch).to receive(:new).and_return(fetcher)
    allow(fetcher).to receive(:call) do |url, **_|
      calls << url
      raise ExternalBridge::Error, :rate_limited
    end

    expect do
      ExternalBridge::RSS::Media::Fetch.new.call(resource.id, resource.media_revision, digest(webp_url))
    end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'rate_limited' }
    expect(calls).to eq [webp_url]
  end

  it 'moves the attachment onto a ready fallback without touching the revisions' do
    stub_feed(webp: { status: 404, body: '', headers: { 'Content-Type' => 'text/plain' } }, png: png_response('"png-1"'))
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

    resource = ExternalResource.find_by!(title: 'Story')
    marker = ExternalStatusProjection.find_by!(user_id: user.id)
    status = Status.find(marker.status_id)
    text = status.text
    text_revision = resource.revision
    media_revision = resource.media_revision
    previous = ExternalMediaAsset.find_by!(url_digest: digest(png_url))
    previous_attachment_id = status.media_attachments.pick(:id)
    c_url = 'https://cdn.example/a-c.png'
    store_png(c_url)

    candidate = resource.media_candidates.first.merge('fallbacks' => [c_url])
    resource.update!(media_candidates: [candidate])
    expect(resource.media_revision).to eq media_revision
    expect(ExternalBridge::RSS::MediaDigest.hexdigest(resource.media_candidates)).to eq media_revision

    WebMock.reset_executed_requests!
    refresh!(resource)

    status.reload
    marker.reload
    link = marker.external_projection_attachments.find_by!(kind: 'image')
    chosen = ExternalMediaAsset.find_by!(url_digest: digest(c_url))
    expect(status.media_attachments.count).to eq 1
    expect(link.external_media_asset_id).to eq chosen.id
    expect(link.media_attachment_id).to eq status.media_attachments.pick(:id)
    sequence = ExternalBridge::RSS::Media::Sequence.for(marker)
    expect(sequence).to eq [
      { type: 'image', delivery: 'local', attachment_id: status.media_attachments.first.id.to_s, position: 0, description: 'Story' },
    ]
    expect(status.text).to eq text
    expect(resource.reload.revision).to eq text_revision
    expect(resource.media_revision).to eq media_revision
    expect(marker.last_seen_media_revision).to eq media_revision
    expect(ExternalMediaGcIntent.find_by!(target_type: 'external_media_asset', target_id: previous.id)).to have_attributes(state: 'released', reason: 'asset_unreferenced')
    expect(ExternalMediaAsset.find_by(id: previous.id)).to be_nil
    expect(ExternalMediaGcIntent.find_by!(target_type: 'media_attachment', target_id: previous_attachment_id)).to have_attributes(state: 'released', reason: 'attachment_replaced')
    expect(ExternalMediaAssetResource.where(external_media_asset_id: previous.id, external_resource_id: resource.id)).to be_empty
    expect(ExternalMediaAssetResource.where(external_media_asset_id: chosen.id, external_resource_id: resource.id).count).to eq 1
    expect(a_request(:get, webp_url)).not_to have_been_made
    expect(a_request(:get, png_url)).not_to have_been_made
    expect(a_request(:get, c_url)).not_to have_been_made
  end

  it 'fetches a fallback added after the previous set was exhausted' do
    c_url = 'https://cdn.example/a-c.png'
    resource = publish_candidate('url' => webp_url, 'kind' => 'image', 'fallbacks' => [png_url], 'description' => 'Story')
    revision = ExternalBridge::RSS::MediaDigest.hexdigest(resource.media_candidates)
    resource.update!(media_revision: revision)
    marker = ExternalStatusProjection.find_by!(external_resource_id: resource.id)
    marker.update!(last_seen_revision: resource.revision, last_seen_media_revision: revision)
    stub_request(:get, webp_url).to_return(status: 404, body: '')
    stub_request(:get, png_url).to_return(status: 404, body: '')

    3.times { ExternalBridge::RSS::Media::Fetch.new.call(resource.id, revision, digest(webp_url)) }

    primary = ExternalMediaAsset.find_by!(url_digest: digest(webp_url))
    fingerprint = ExternalBridge::RSS::Media::ImageAttempts.fingerprint(resource.media_candidates.first)
    expect(primary.attempt_count).to eq 3
    expect(primary.exhausted_for?(revision, fingerprint)).to be true
    expect(primary.attempt_log.map { |row| row['code'] }).to eq %w(http_404 http_404)
    expect(ExternalMediaAsset.find_by!(url_digest: digest(png_url)).failure_code).to eq 'http_404'

    WebMock.reset_executed_requests!
    ExternalBridge::RSS::Media::Fetch.new.call(resource.id, revision, digest(webp_url))
    expect(a_request(:get, webp_url)).not_to have_been_made
    expect(a_request(:get, png_url)).not_to have_been_made

    updated = resource.media_candidates.first.merge('fallbacks' => [c_url])
    expect(ExternalBridge::RSS::MediaDigest.hexdigest([updated])).to eq revision
    resource.update!(media_candidates: [updated])
    stub_request(:get, c_url).to_return(png_response)
    refresh!(resource)

    chosen = ExternalMediaAsset.find_by!(url_digest: digest(c_url))
    expect(chosen).to be_ready
    expect(marker.reload.external_projection_attachments.find_by!(kind: 'image').external_media_asset_id).to eq chosen.id
    expect(Status.find(marker.status_id).media_attachments.count).to eq 1
    expect(primary.reload.failure_code).to eq 'alternate_selected'
    expect(primary.attempt_count).to eq 0
    expect(primary.exhausted_for?(revision, ExternalBridge::RSS::Media::ImageAttempts.fingerprint(updated))).to be false
    expect(resource.reload.media_revision).to eq revision
    sequence = ExternalBridge::RSS::Media::Sequence.for(marker)
    expect(sequence.first[:attachment_id]).to eq Status.find(marker.status_id).media_attachments.pick(:id).to_s
  end

  it 'drops the attached image when the fallback list is removed' do
    stub_feed(webp: { status: 404, body: '' }, png: png_response)
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

    resource = ExternalResource.find_by!(title: 'Story')
    marker = ExternalStatusProjection.find_by!(user_id: user.id)
    status = Status.find(marker.status_id)
    text = status.text
    text_revision = resource.revision
    media_revision = resource.media_revision
    previous = ExternalMediaAsset.find_by!(url_digest: digest(png_url))
    candidate = resource.media_candidates.first.except('fallbacks')
    resource.update!(media_candidates: [candidate])
    expect(ExternalBridge::RSS::MediaDigest.hexdigest(resource.media_candidates)).to eq media_revision

    refresh!(resource)

    expect(status.reload.media_attachments).to be_empty
    expect(ExternalBridge::RSS::Media::Sequence.for(marker.reload)).to eq []
    expect(status.text).to eq text
    expect(resource.reload.revision).to eq text_revision
    expect(resource.media_revision).to eq media_revision
    expect(marker.last_seen_media_revision).to eq media_revision
    expect(ExternalMediaGcIntent.find_by!(target_type: 'external_media_asset', target_id: previous.id)).to have_attributes(state: 'released', reason: 'asset_unreferenced')
    expect(ExternalMediaAsset.find_by(id: previous.id)).to be_nil
    expect(ExternalMediaAssetResource.where(external_media_asset_id: previous.id, external_resource_id: resource.id)).to be_empty
  end

  it 'records each failed URL and refetches when the stored fallback is not ready' do
    stub_feed(
      webp: { status: 200, body: 'not-an-image', headers: { 'Content-Type' => 'image/webp' } },
      png: { status: 404, body: '' }
    )
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

    resource = ExternalResource.find_by!(title: 'Story')
    primary = ExternalMediaAsset.find_by!(url_digest: digest(webp_url))
    expect(primary.failure_code).to eq 'http_404'
    expect(primary.attempt_log.map { |row| row['code'] }).to eq %w(media_type_mismatch http_404)
    expect(primary.attempt_log.map { |row| row['digest'] }).to eq [digest(webp_url), digest(png_url)]
    expect(ExternalMediaAsset.find_by!(url_digest: digest(png_url)).failure_code).to eq 'http_404'
    expect(Status.find(ExternalStatusProjection.find_by!(user_id: user.id).status_id).media_attachments).to be_empty

    primary.delete
    ExternalMediaAsset.where(url_digest: digest(png_url)).delete_all
    WebMock.reset_executed_requests!
    stub_request(:get, webp_url).to_return(status: 404, body: '')
    stub_request(:get, png_url).to_return(png_response('"png-live"'))
    ExternalBridge::RSS::Media::Fetch.new.call(resource.id, resource.media_revision, digest(webp_url))

    stored = ExternalMediaAsset.find_by!(url_digest: digest(png_url))
    primary = ExternalMediaAsset.find_by!(url_digest: digest(webp_url))
    expect(stored).to be_ready
    expect(primary.failure_code).to eq 'alternate_selected'
    expect(primary.attempt_count).to eq 0
    expect(primary.attempt_log.map { |row| row['code'] }).to eq %w(http_404 stored)
    marker = ExternalStatusProjection.find_by!(user_id: user.id)
    expect(marker.external_projection_attachments.find_by!(kind: 'image').external_media_asset_id).to eq stored.id

    stored.update_columns(state: 'failed', failure_code: 'local_missing')
    expect(Status.find(marker.status_id).media_attachments.count).to eq 1
    WebMock.reset_executed_requests!
    stub_request(:get, webp_url).to_return(status: 404, body: '')
    stub_request(:get, png_url).to_return(png_response('"png-again"'))
    refresh!(resource)

    expect(a_request(:get, webp_url)).to have_been_made.once
    expect(a_request(:get, png_url)).to have_been_made.once
    expect(stored.reload).to be_ready
    expect(stored.validator_etag).to eq '"png-again"'
    expect(primary.reload.failure_code).to eq 'alternate_selected'
    expect(primary.attempt_count).to eq 0
    expect(primary.attempt_log.map { |row| row['code'] }).to eq %w(http_404 stored)
    expect(Status.find(marker.status_id).media_attachments.count).to eq 1
    expect(marker.reload.external_projection_attachments.find_by!(kind: 'image').external_media_asset_id).to eq stored.id
  end

  it 'opens a new fallback fingerprint and an alternate that is no longer ready' do
    asset = ExternalMediaAsset.create!(
      url_digest: Digest::SHA256.hexdigest('chain-open'),
      kind: 'image',
      state: 'failed',
      failure_code: 'http_404',
      failed_revision: 'rev-media',
      attempt_count: 3,
      candidate_fingerprint: 'a' * 64
    )
    attempts = ExternalBridge::RSS::Media::ImageAttempts
    expect(asset.exhausted_for?('rev-media', 'a' * 64)).to be true
    expect(attempts.chain_open?(asset, 'rev-media', 'a' * 64)).to be false
    expect(asset.exhausted_for?('rev-media', 'b' * 64)).to be false
    expect(attempts.chain_open?(asset, 'rev-media', 'b' * 64)).to be true

    asset.update!(failure_code: 'alternate_selected', attempt_count: 0)
    expect(attempts.chain_open?(asset, 'rev-media', 'a' * 64)).to be true
    same = attempts.fingerprint('url' => webp_url, 'kind' => 'image', 'fallbacks' => [png_url])
    with_junk = attempts.fingerprint('url' => webp_url, 'kind' => 'image', 'fallbacks' => [png_url, 'javascript:alert(1)'])
    changed = attempts.fingerprint('url' => webp_url, 'kind' => 'image', 'fallbacks' => ['https://cdn.example/a-c.png'])
    expect(with_junk).to eq same
    expect(changed).not_to eq same
  end

  it 'restores a missing fallback file from the representative digest when 304 persists' do
    stub_feed(webp: { status: 404, body: '' }, png: png_response('"png-1"'))
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

    resource = ExternalResource.find_by!(title: 'Story')
    marker = ExternalStatusProjection.find_by!(user_id: user.id)
    stored = ExternalMediaAsset.find_by!(url_digest: digest(png_url))
    primary = ExternalMediaAsset.find_by!(url_digest: digest(webp_url))
    expect(primary.failure_code).to eq 'alternate_selected'
    expect(stored).to be_ready
    expect(Status.find(marker.status_id).media_attachments.count).to eq 1
    stored.update_columns(validated_at: 25.hours.ago, revalidate_after: nil, revalidate_attempt: 0)
    FileUtils.rm_f(stored.file.path)
    WebMock.reset_executed_requests!
    stub_request(:get, png_url).with(headers: { 'If-None-Match' => '"png-1"' }).to_return(status: 304, body: '')

    fetch_args = nil
    Sidekiq::Testing.fake! do
      ExternalBridge::RSS::MediaFetchWorker.clear
      expect(ExternalBridge::RSS::Media::Revalidate.call(resource.id, stored.url_digest)).to eq :local_missing
      expect(stored.reload).not_to be_ready
      expect(stored.failure_code).to eq 'local_missing'
      expect(ExternalBridge::RSS::MediaFetchWorker.jobs.size).to eq 1
      fetch_args = ExternalBridge::RSS::MediaFetchWorker.jobs.last['args']
    end
    expect(fetch_args).to eq [resource.id, resource.media_revision, digest(webp_url)]

    ExternalBridge::RSS::MediaFetchWorker.new.perform(*fetch_args)

    expect(a_request(:get, png_url).with(headers: { 'If-None-Match' => '"png-1"' })).to have_been_made.once
    expect(a_request(:get, png_url)).to have_been_made.twice
    expect(a_request(:get, webp_url)).to have_been_made.once
    expect(stored.reload).to be_ready
    expect(stored.failure_code).to be_nil
    expect(stored.file.exists?).to be true
    expect(stored.fingerprint).to eq Digest::SHA256.hexdigest(png)
    expect(primary.reload.failure_code).to eq 'alternate_selected'
    expect(Status.find(marker.status_id).media_attachments.count).to eq 1
    expect(marker.reload.external_projection_attachments.find_by!(kind: 'image').external_media_asset_id).to eq stored.id

    stored.update_columns(validated_at: 25.hours.ago, revalidate_after: nil)
    expect(ExternalBridge::RSS::Media::Revalidate.call(resource.id, stored.url_digest)).to eq :not_modified
    expect(stored.reload).to be_ready
    expect(a_request(:get, png_url).with(headers: { 'If-None-Match' => '"png-1"' })).to have_been_made.twice
  end

  it 'revalidates the URL that was actually stored' do
    stub_feed(webp: { status: 404, body: '' }, png: png_response('"png-1"'))
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    asset = ExternalMediaAsset.find_by!(url_digest: digest(png_url))
    asset.update_columns(validated_at: 25.hours.ago, revalidate_after: nil)
    stub_request(:get, png_url).with(headers: { 'If-None-Match' => '"png-1"' }).to_return(status: 304, body: '')

    result = ExternalBridge::RSS::Media::Revalidate.call(ExternalResource.find_by!(title: 'Story').id, asset.url_digest)

    expect(result).to eq :not_modified
    expect(a_request(:get, png_url).with(headers: { 'If-None-Match' => '"png-1"' })).to have_been_made.once
    expect(a_request(:get, webp_url).with(headers: { 'If-None-Match' => '"png-1"' })).not_to have_been_made
  end

  it 'leaves an in-progress generation checkpoint in place when only fallbacks change' do
    stub_feed(webp: { status: 404, body: '' }, png: png_response('"png-1"'))
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)

    resource = ExternalResource.find_by!(title: 'Story')
    marker = ExternalStatusProjection.find_by!(user_id: user.id)
    stored = ExternalMediaAsset.find_by!(url_digest: digest(png_url))
    media_revision = resource.media_revision
    text_revision = resource.revision
    link = marker.external_projection_attachments.find_by!(kind: 'image')
    expect(link.external_media_asset_id).to eq stored.id

    incoming = store_png_digest(ExternalBridge::RSS::Media::ReplaceGeneration.checkpoint_digest(stored.id))
    expect(ExternalBridge::RSS::Media::ReplaceGeneration.pending?(stored.reload)).to be true
    c_url = 'https://cdn.example/a-c.png'
    store_png(c_url)
    resource.update!(media_candidates: [resource.media_candidates.first.merge('fallbacks' => [c_url])])
    expect(ExternalBridge::RSS::Media::Sync.links_stale?(marker, resource)).to be false

    refresh!(resource)

    expect(link.reload.external_media_asset_id).to eq stored.id
    expect(stored.reload).to be_ready
    expect(stored.url_digest).to eq digest(png_url)
    expect(incoming.reload).to be_ready
    expect(incoming.url_digest).to eq ExternalBridge::RSS::Media::ReplaceGeneration.checkpoint_digest(stored.id)
    expect(resource.reload.media_revision).to eq media_revision
    expect(resource.revision).to eq text_revision
    expect(marker.reload.last_seen_media_revision).to eq media_revision
    expect(Status.find(marker.status_id).media_attachments.count).to eq 1

    link.update!(external_media_asset: incoming)
    resource.update!(media_candidates: [resource.media_candidates.first.merge('fallbacks' => [png_url])])
    expect(ExternalBridge::RSS::Media::Sync.links_stale?(marker.reload, resource)).to be false

    refresh!(resource)

    expect(link.reload.external_media_asset_id).to eq incoming.id
    expect(incoming.reload.url_digest).to eq ExternalBridge::RSS::Media::ReplaceGeneration.checkpoint_digest(stored.id)
    expect(stored.reload).to be_ready
    expect(stored.url_digest).to eq digest(png_url)
    expect(Status.find(marker.status_id).media_attachments.count).to eq 1
    expect(resource.reload.media_revision).to eq media_revision
  end

  it 'keeps the resource link when the stored fallback body changes' do
    stub_feed(webp: { status: 404, body: '' }, png: png_response('"png-1"'))
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    resource = ExternalResource.find_by!(title: 'Story')
    asset = ExternalMediaAsset.find_by!(url_digest: digest(png_url))
    old_id = asset.id
    asset.update_columns(validated_at: 25.hours.ago, revalidate_after: nil)
    jpeg = Rails.root.join('spec', 'fixtures', 'files', 'attachment.jpg').binread
    stub_request(:get, png_url).with(headers: { 'If-None-Match' => '"png-1"' }).to_return(
      status: 200, body: jpeg, headers: { 'Content-Type' => 'image/jpeg', 'ETag' => '"png-2"' }
    )

    result = ExternalBridge::RSS::Media::Revalidate.call(resource.id, asset.url_digest)

    expect(result).to eq :replaced
    replacement = ExternalMediaAsset.find_by!(url_digest: digest(png_url))
    expect(replacement.id).not_to eq old_id
    expect(replacement.generation).to eq 2
    expect(ExternalMediaAsset.find_by(id: old_id)).to be_nil
    expect(ExternalMediaAssetResource.where(external_media_asset_id: replacement.id, external_resource_id: resource.id).count).to eq 1
    status = Status.find(ExternalStatusProjection.find_by!(user_id: user.id).status_id)
    expect(status.media_attachments.count).to eq 1
    expect(status.media_attachments.first.file_content_type).to eq 'image/jpeg'
    expect(a_request(:get, webp_url).with(headers: { 'If-None-Match' => '"png-1"' })).not_to have_been_made
  end

  def refresh!(resource)
    subscription = ExternalSubscription.find_by!(external_source_id: resource.external_source_id, user_id: user.id)
    ExternalBridge::RSS::Materialize.new.call(subscription: subscription, resources: [resource])
  end

  def store_png(url)
    store_png_digest(digest(url))
  end

  def store_png_digest(url_digest)
    ExternalBridge::RSS::Media::AssetStore.store!(
      url_digest: url_digest,
      kind: 'image',
      revision: 'stored',
      result: ExternalBridge::RSS::Media::ImageFetch::Result.new(
        body: png,
        type: :png,
        content_type: 'image/png',
        width: 1,
        height: 1,
        fingerprint: Digest::SHA256.hexdigest(png)
      )
    )
  end

  def stub_feed(webp:, png:)
    stub_request(:get, webp_url).to_return(webp)
    stub_request(:get, png_url).to_return(png)
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml))
  end

  def png_response(etag = nil)
    headers = { 'Content-Type' => 'image/png' }
    headers['ETag'] = etag if etag
    { status: 200, body: png, headers: headers }
  end

  def item_xml
    <<~XML
      <item>
        <guid>story</guid>
        <title>Story</title>
        <link>https://example.com/story</link>
        <description><![CDATA[
          <picture>
            <source type="image/webp" srcset="#{webp_url} 800w">
            <source type="image/png" srcset="#{png_url} 800w">
            <img src="#{png_url}" alt="Story">
          </picture>
        ]]></description>
      </item>
    XML
  end

  def digest(url)
    ExternalBridge::RSS::MediaDigest.url_digest(url)
  end

  def publish_candidate(candidate)
    source = ExternalSource.create!(
      protocol: 'rss', canonical_key: feed_url, title: 'Feed', site_url: 'https://example.com',
      etag: 'W/"f"', fetched_at: Time.current, checked_at: Time.current
    )
    resource = ExternalResource.create!(
      external_source: source, protocol: 'rss', canonical_key: "feed:#{feed_url}\nitem:story",
      title: 'Story', body: 'Story', canonical_url: 'https://example.com/story', revision: 'rev',
      media_candidates: [candidate], media_revision: 'rev-media', published_at: Time.current, fetched_at: Time.current
    )
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    status = Status.create!(account: user.account, text: 'Story', visibility: :external, searchability: :personal, external_projection: true, local: true)
    ExternalStatusProjection.create!(
      user_id: user.id, account_id: user.account_id, external_source_id: source.id,
      external_subscription_id: subscription.id, external_resource_id: resource.id,
      status_id: status.id, last_seen_revision: resource.revision
    )
    resource
  end
end
