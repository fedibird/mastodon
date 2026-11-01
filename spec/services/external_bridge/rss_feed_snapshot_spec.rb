# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'RSS snapshot drain' do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/news.xml' }

  before do
    enable_external_bridge_rss!(user, other)
  end

  describe 'Parser.index!' do
    it 'counts keyed items past the parse! page and ignores a keyless node' do
      body = rss_document(
        '<item><title>no key</title><description>skip</description></item>' +
        items_xml(page + 1)
      )

      expect(ExternalBridge::RSS::Parser.parse!(body).items.compact.size).to be <= page
      expect(ExternalBridge::RSS::Parser.index!(body).keyed_items.size).to eq(page + 1)
    end
  end

  describe 'continued import' do
    it 'imports an empty feed without a projection' do
      subscribe_feed(rss_document(''))

      expect(resources.count).to eq(0)
      expect(ExternalStatusProjection.count).to eq(0)
      expect(ExternalFeedSnapshot.last.state).to eq('complete')
    end

    it 'keeps a 40 item feed on the history page and does not open a tail' do
      subscribe_feed(feed_xml(page))

      expect(resources.count).to eq(page)
      expect(projections_for(user).size).to eq(page)
      expect(ExternalFeedSnapshot.last.state).to eq('complete')
      expect(ExternalFeedSnapshot.open.where(external_source_id: source_id).count).to eq(0)
    end

    it 'imports the 41st item for a subscriber that already existed' do
      subscribe_feed(feed_xml(1))
      refresh_feed(feed_xml(page + 1))

      expect(resource_guids).to match_array((0..page).map { |index| "guid-#{index}" })
      expect(projection_guids(user)).to match_array(resource_guids)
    end

    it 'gives a new subscriber the history page and still stores the tail' do
      subscribe_feed(feed_xml(page + 1, order: :oldest_first))

      expect(resources.count).to eq(page + 1)
      expect(projections_for(user).size).to eq(page)
      expect(projection_guids(user)).not_to include('guid-0')
      expect(resource_guids).to include('guid-0')
    end

    it 'drains more than two batches and records the cost of an 81 item feed' do
      batches = 0
      allow_any_instance_of(ExternalBridge::RSS::FeedSnapshot::Drain).to receive(:apply_batch!).and_wrap_original do |method, *arguments|
        batches += 1
        method.call(*arguments)
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rss_before = rss_kb
      subscribe_feed(feed_xml(1))
      refresh_feed(feed_xml(81))
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(resources.count).to eq(81)
      expect(projections_for(user).size).to eq(81)
      expect(ExternalStatusProjection.where(user_id: user.id).distinct.count(:external_resource_id)).to eq(81)
      expect(batches).to be >= 2
      write_measurement(elapsed, rss_before, batches)
      expect(elapsed).to be < 60
    end

    it 'imports every guid when the first page is already stored and the new item is last' do
      subscribe_feed(feed_xml(page))
      body = rss_document(items_xml(page) + rss_item(guid: 'guid-new', title: 'Brand new', link: 'https://example.com/i/new', date: stamp(Time.utc(2024, 6, 1))))
      refresh_feed(body)

      expect(resource_guids).to include('guid-new')
      expect(projection_guids(user)).to include('guid-new')
      expect(resources.count).to eq(page + 1)
    end

    it 'imports oldest-first, newest-first, irregular, identical, and missing dates without dropping guids' do
      subscribe_feed(feed_xml(1))
      refresh_feed(feed_xml(page + 1, order: :irregular))
      fresh = projections_for(user).includes(:external_resource, :status).reject { |row| guid_from_resource(row.external_resource) == 'guid-0' }
      expect(fresh.map { |row| row.status.created_at.to_i }.sort).to eq(fresh.map { |row| row.external_resource.published_at.to_i }.sort)
      expect(fresh.map(&:status_id).sort).to eq(fresh.sort_by { |row| row.status.created_at }.map(&:status_id))
      expect(projection_guids(user).size).to eq(page + 1)

      refresh_feed(feed_xml(page + 1, order: :oldest_first))
      expect(projection_guids(user).size).to eq(page + 1)
      refresh_feed(feed_xml(page + 1, order: :newest_first))
      expect(resources.count).to eq(page + 1)
      refresh_feed(feed_xml(page + 1, order: :same))
      expect(resources.count).to eq(page + 1)
      refresh_feed(feed_xml(page + 1, order: :missing))
      expect(resources.where(published_at: nil).count).to eq(page + 1)
      expect(projections_for(user).size).to eq(page + 1)
    end

    it 'keeps one resource when a guid is repeated and lets the later item win' do
      subscribe_feed(feed_xml(1))
      body = rss_document(
        rss_item(guid: 'guid-dup', title: 'First title', link: 'https://example.com/i/dup') +
        rss_item(guid: 'guid-dup', title: 'Second title', link: 'https://example.com/i/dup-2') +
        rss_item(guid: 'guid-other', title: 'Other', link: 'https://example.com/i/other')
      )
      refresh_feed(body)

      expect(resources.where('canonical_key LIKE ?', '%item:guid-dup').count).to eq(1)
      expect(resources.find_by(title: 'Second title')).to be_present
      expect(resources.find_by(title: 'First title')).to be_nil
      expect(projection_guids(user)).to include('guid-dup', 'guid-other')
    end

    it 'updates an existing item without renumbering the resource or the status' do
      subscribe_feed(feed_xml(1, order: :newest_first))
      marker = projections_for(user).first
      resource_id = marker.external_resource_id
      status_id = marker.status_id
      created_at = marker.status.created_at
      refresh_feed(feed_xml(page + 1, order: :oldest_first, title_for: ->(index) { index.zero? ? 'Updated title' : "T#{index}" }))

      marker.reload
      expect(marker.external_resource_id).to eq(resource_id)
      expect(marker.status_id).to eq(status_id)
      expect(marker.status.created_at).to eq(created_at)
      expect(marker.external_resource.title).to eq('Updated title')
      expect(marker.status.text).to include('Updated title')
    end

    it 'shares one resource and separate projections across subscribers' do
      subscribe_feed(feed_xml(1))
      described_class_subscribe(other, feed_xml(1))
      refresh_feed(feed_xml(page + 1))

      expect(resources.count).to eq(page + 1)
      expect(projection_guids(user)).to match_array(projection_guids(other))
      expect(projections_for(user).pluck(:status_id)).not_to match_array(projections_for(other).pluck(:status_id))
    end

    it 'does not re-sample language or overwrite subscriber presentation' do
      subscribe_feed(feed_xml(1))
      subscription = ExternalSubscription.find_by!(user_id: user.id)
      subscription.update!(language_mode: 'fixed', language: 'ja', cw_enabled: true, media_sensitive: true)
      expect(ExternalBridge::RSS::InitialLanguage).not_to receive(:attributes_for)
      refresh_feed(feed_xml(page + 1))

      subscription.reload
      expect(subscription.language_mode).to eq('fixed')
      expect(subscription.language).to eq('ja')
      expect(subscription.cw_enabled).to be true
      expect(subscription.media_sensitive).to be true
      expect(Status.where(id: projections_for(user).select(:status_id)).pluck(:language).uniq).to eq(['ja'])
    end
  end

  describe 'failure and concurrency' do
    it 'rolls back an item when the cursor update does not commit, then retries without a duplicate' do
      subscribe_feed(feed_xml(1))
      raised = false
      allow_any_instance_of(ExternalBridge::RSS::FeedSnapshot::Drain).to receive(:before_progress!).and_wrap_original do |method, *arguments|
        unless raised
          raised = true
          raise 'killed after save'
        end
        method.call(*arguments)
      end
      body = feed_xml(page + 1, order: :newest_first)
      stub_request(:get, feed_url).to_return(status: 200, body: body, headers: { 'ETag' => 'W/"tail"' })
      expect { refresh_feed_without_stub }.to raise_error('killed after save')

      snapshot = ExternalFeedSnapshot.order(:id).last
      expect(snapshot.next_index).to eq(page)
      expect(resources.count).to eq(page)
      expect { refresh_without_http }.not_to raise_error
      expect(resources.count).to eq(page + 1)
      expect(resources.distinct.count(:canonical_key)).to eq(page + 1)
    end

    it 'fails the snapshot observably after the attempt ceiling' do
      subscribe_feed(feed_xml(1))
      allow_any_instance_of(ExternalBridge::RSS::FeedSnapshot::Drain).to receive(:before_progress!).and_raise('poison')
      stub_request(:get, feed_url).to_return(status: 200, body: feed_xml(page + 1), headers: { 'ETag' => 'W/"poison"' })
      expect { refresh_feed_without_stub }.to raise_error('poison')
      3.times { expect { ExternalBridge::RSS::FeedSnapshot::Drain.new.advance!(source_id) }.to raise_error('poison') }
      expect { ExternalBridge::RSS::FeedSnapshot::Drain.new.advance!(source_id) }.not_to raise_error

      snapshot = ExternalFeedSnapshot.order(:generation).last
      expect(snapshot.state).to eq('incomplete')
      expect(snapshot.isolated_entries.map { |entry| entry['position'] }).to include(page)
      expect(snapshot.next_index).to eq(snapshot.item_count)
      expect(resources.count).to eq(page)

      allow_any_instance_of(ExternalBridge::RSS::FeedSnapshot::Drain).to receive(:before_progress!).and_call_original
      expect(ExternalBridge::RSS::FeedSnapshot::Retry.call(snapshot.id)).to eq(:queued)
      expect(resources.count).to eq(page + 1)
      expect(ExternalFeedSnapshot.find(snapshot.id).state).to eq('complete')
    end

    it 'does not let a second worker take a live lease, and resumes after the lease lapses' do
      subscribe_feed(feed_xml(1))
      hold_drain
      refresh_feed(feed_xml(page + 1, order: :newest_first))
      snapshot = ExternalFeedSnapshot.open.order(:id).last
      token = snapshot.claim_lease!
      expect(ExternalBridge::RSS::FeedSnapshot::Drain.new.advance!(snapshot.external_source_id)).to eq(:busy)
      expect(snapshot.reload.lease_token).to eq(token)
      snapshot.update_columns(lease_expires_at: 1.minute.ago)
      expect(ExternalBridge::RSS::FeedSnapshot::Drain.new.advance!(snapshot.external_source_id)).to eq(:ok)
      expect(resources.count).to eq(page + 1)
    end
  end

  describe 'generations, 304, and subscription fences' do
    it 'keeps an open body when a newer response arrives and applies the older generation first' do
      subscribe_feed(feed_xml(1))
      hold_drain
      older = rss_document(items_xml(page + 1, order: :newest_first) + rss_item(guid: 'guid-only-old', title: 'Only old', link: 'https://example.com/i/only-old', date: stamp(Time.utc(2019, 1, 1))))
      refresh_feed(older)
      first = ExternalFeedSnapshot.order(:id).last
      expect(first.body).to include('guid-only-old')
      newer = (0...page).map { |index|
        rss_item(guid: "guid-#{index}", title: "U#{index}", link: "https://example.com/i/#{index}", date: stamp(Time.utc(2024, 6, 1) - index.days))
      }.join + rss_item(guid: 'guid-only-new', title: 'Only new', link: 'https://example.com/i/only-new', date: stamp(Time.utc(2019, 2, 1)))
      refresh_feed(rss_document(newer))

      expect(ExternalFeedSnapshot.where(external_source_id: source_id).order(:generation).pluck(:generation)).to eq([1, 2, 3])
      expect(ExternalFeedSnapshot.find(first.id).body).to include('guid-only-old')
      expect(resources.find_by(title: 'Only old')).to be_nil
      release_drain
      ExternalBridge::RSS::FeedSnapshotDrainWorker.new.perform(source_id)

      expect(resources.find_by(title: 'Only old')).to be_present
      expect(resources.find_by(title: 'Only new')).to be_present
      expect(resources.find_by(title: 'U0')).to be_present
      expect(projection_guids(user)).to include('guid-only-old', 'guid-only-new')
    end

    it 'continues an open snapshot on 304 instead of dropping it' do
      subscribe_feed(feed_xml(1))
      hold_drain
      refresh_feed(feed_xml(page + 1, order: :newest_first))
      expect(resources.count).to eq(page)
      snapshot = ExternalFeedSnapshot.open.last
      release_drain
      stub_request(:get, feed_url).to_return(status: 304, headers: { 'ETag' => 'W/"same"' })
      refresh_feed_without_stub

      expect(ExternalFeedSnapshot.find(snapshot.id).state).to eq('complete')
      expect(ExternalFeedSnapshot.find(snapshot.id).body).to include('guid-0')
      expect(resources.count).to eq(page + 1)
    end

    it 'does not project a fenced subscriber or revive that backlog on resubscribe' do
      subscribe_feed(feed_xml(1))
      described_class_subscribe(other, feed_xml(1))
      fenced = ExternalSubscription.find_by!(user_id: user.id)
      fenced.update_columns(state: 'deleting')
      refresh_feed(feed_xml(page + 1, order: :oldest_first), subscriber: other)

      expect(projections_for(user).size).to eq(1)
      expect(projections_for(other).size).to eq(page + 1)
      destroyed_status_id = projections_for(user).first.status_id
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL fedibird.projection_status_delete = 'on'")
        projections_for(user).delete_all
        Status.where(id: destroyed_status_id).delete_all
      end
      fenced.update_columns(state: 'active', created_at: Time.current)
      described_class_subscribe(user, feed_xml(page + 1, order: :oldest_first))

      expect(projections_for(user).size).to eq(page)
      expect(projection_guids(user)).not_to include('guid-0')
      expect(Status.where(id: destroyed_status_id)).to be_empty
      expect(projections_for(other).size).to eq(page + 1)
    end

    it 'catches up an item imported while the subscription was paused' do
      subscribe_feed(feed_xml(1))
      hold_drain
      tail = rss_item(guid: 'guid-tail', title: 'Tail', link: 'https://example.com/i/tail', date: stamp(Time.utc(2019, 1, 1)))
      refresh_feed(rss_document(items_xml(page, order: :newest_first) + tail))
      expect(projection_guids(user)).not_to include('guid-tail')
      ExternalSubscription.find_by!(user_id: user.id).update_columns(state: 'paused')
      release_drain
      ExternalBridge::RSS::FeedSnapshotDrainWorker.new.perform(source_id)
      expect(resource_guids).to include('guid-tail')
      expect(projection_guids(user)).not_to include('guid-tail')

      stub_request(:get, feed_url).to_return(status: 304)
      ExternalBridge::RSS::Subscribe.new.resume!(user: user, subscription_id: ExternalSubscription.find_by!(user_id: user.id).id)
      expect(projection_guids(user)).to include('guid-tail')
    end
  end

  describe 'remainder, catch-up, and retention' do
    it 'blocks a newer generation until the failed remainder is explicitly retried' do
      subscribe_feed(feed_xml(1))
      older_id = nil
      Sidekiq::Testing.fake! do
        ExternalBridge::RSS::FeedSnapshotDrainWorker.jobs.clear
        refresh_feed(feed_xml(page + 1, order: :newest_first))
        older = ExternalFeedSnapshot.open.order(:generation).last
        older_id = older.id
        newer_body = rss_document(items_xml(page, order: :newest_first) + rss_item(guid: 'guid-only-new', title: 'Only new', link: 'https://example.com/i/only-new', date: stamp(Time.utc(2019, 2, 1))))
        refresh_feed(newer_body)
        stub_const('ExternalBridge::RSS::Limits::SNAPSHOT_MAX_BATCHES', 0)
        expect(ExternalBridge::RSS::FeedSnapshot::Drain.new.advance!(source_id)).to eq(:ok)
        expect(older.reload.state).to eq('failed')
        expect(older.next_index).to be < older.item_count
        expect(ExternalBridge::RSS::FeedSnapshot::Drain.new.advance!(source_id)).to eq(:blocked)
        expect(resource_guids).not_to include('guid-only-new')

        stub_const('ExternalBridge::RSS::Limits::SNAPSHOT_MAX_BATCHES', 160)
        expect(ExternalBridge::RSS::FeedSnapshot::Retry.call(older.id)).to eq(:queued)
      end
      ExternalBridge::RSS::FeedSnapshotDrainWorker.new.perform(source_id)
      expect(resource_guids).to include('guid-only-new')
      expect(ExternalFeedSnapshot.find(older_id).state).to eq('complete')
    end

    it 'advances catch-up one batch per job across 4000-item generations and stops when fenced' do
      subscribe_feed(feed_xml(1))
      subscription = ExternalSubscription.find_by!(user_id: user.id)
      Sidekiq::Testing.fake! do
        ExternalBridge::RSS::FeedSnapshotDrainWorker.jobs.clear
        refresh_feed(feed_xml(4_000, order: :oldest_first))
        refresh_feed(feed_xml(4_000, order: :newest_first))
        generations = ExternalFeedSnapshot.where('item_count >= 4000').order(:generation).to_a
        expect(generations.size).to eq(2)

        ExternalBridge::RSS::FeedSnapshotCatchUpWorker.jobs.clear
        ExternalBridge::RSS::FeedSnapshot::CatchUp.enqueue!(subscription)
        ExternalBridge::RSS::FeedSnapshot::CatchUp.advance!(subscription.id)
        row = ExternalFeedCatchUp.find_by!(external_subscription_id: subscription.id)
        expect(row.external_feed_snapshot_id).to eq(generations.first.id)
        expect(row.position).to eq(ExternalBridge::RSS::Limits::SNAPSHOT_BATCH_ITEMS)

        ExternalBridge::RSS::FeedSnapshot::CatchUp.advance!(subscription.id)
        expect(row.reload.position).to eq(ExternalBridge::RSS::Limits::SNAPSHOT_BATCH_ITEMS * 2)

        row.update!(position: generations.first.item_count)
        ExternalBridge::RSS::FeedSnapshot::CatchUp.advance!(subscription.id)
        expect(row.reload.external_feed_snapshot_id).to eq(generations.second.id)
        expect(row.position).to eq(ExternalBridge::RSS::Limits::SNAPSHOT_BATCH_ITEMS)

        subscription.update_columns(state: 'deleting')
        ExternalBridge::RSS::FeedSnapshot::CatchUp.advance!(subscription.id)
        expect(row.reload.state).to eq('stopped')
        expect(row.position).to eq(ExternalBridge::RSS::Limits::SNAPSHOT_BATCH_ITEMS)
      end
    end

    it 'keeps one busy retry until the lease wait has passed' do
      subscribe_feed(feed_xml(1))
      Sidekiq::Testing.fake! do
        ExternalBridge::RSS::FeedSnapshotDrainWorker.jobs.clear
        refresh_feed(feed_xml(page + 1, order: :newest_first))
        snapshot = ExternalFeedSnapshot.open.order(:id).last
        snapshot.claim_lease!
        ExternalBridge::RSS::FeedSnapshotDrainWorker.jobs.clear
        ExternalBridge::RSS::FeedSnapshotDrainWorker.new.perform(snapshot.external_source_id)
        ExternalBridge::RSS::FeedSnapshotDrainWorker.new.perform(snapshot.external_source_id)
        expect(ExternalBridge::RSS::FeedSnapshotDrainWorker.jobs.size).to eq(1)
        expect(snapshot.reload.busy_retry_at).to be_within(5.seconds).of(snapshot.lease_expires_at)
      end
    end

    it 'purges eligible finished bodies and refuses retry after the body is gone' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: "https://feeds.example/purge-#{SecureRandom.hex(4)}.xml", title: 'Purge')
      finished = ExternalFeedSnapshot.create!(
        external_source: source, generation: 1, state: 'incomplete', body: '<rss/>', byte_size: 6,
        item_count: 2, next_index: 2, isolated_positions: [{ 'position' => 1, 'code' => 'snapshot_failed' }],
        completed_at: 2.days.ago
      )
      pending = ExternalFeedSnapshot.create!(
        external_source: source, generation: 2, state: 'pending', body: 'keep', byte_size: 4, item_count: 1, next_index: 0
      )
      ExternalBridge::RSS::FeedSnapshot::Purge.call
      expect(finished.reload.body).to be_nil
      expect(finished.body_purged_at).to be_present
      expect(pending.reload.body).to eq('keep')
      expect(ExternalBridge::RSS::FeedSnapshot::Retry.call(finished.id)).to eq(:body_purged)
      expect(finished.reload.last_error_code).to eq('snapshot_body_purged')

      stub_const('ExternalBridge::RSS::Limits::SNAPSHOT_RETAINED_BODY_BYTES', 10)
      older = ExternalFeedSnapshot.create!(
        external_source: source, generation: 3, state: 'complete', body: 'a' * 8, byte_size: 8,
        item_count: 1, next_index: 1, completed_at: 1.hour.ago
      )
      newer = ExternalFeedSnapshot.create!(
        external_source: source, generation: 4, state: 'complete', body: 'b' * 8, byte_size: 8,
        item_count: 1, next_index: 1, completed_at: 1.minute.ago
      )
      ExternalBridge::RSS::FeedSnapshot::Purge.call
      expect(older.reload.body).to be_nil
      expect(newer.reload.body).to eq('b' * 8)
      expect(pending.reload.body).to eq('keep')
    end
  end

  describe 'caps' do
    it 'refuses a body over the item cap without moving validators' do
      subscribe_feed(feed_xml(1))
      etag = ExternalSource.find(source_id).etag
      stub_const('ExternalBridge::RSS::Limits::SNAPSHOT_MAX_ITEMS', 2)
      stub_request(:get, feed_url).to_return(status: 200, body: feed_xml(3), headers: { 'ETag' => 'W/"too-many"' })

      outcome = refresh_feed_without_stub
      expect(outcome[:outcome]).to eq('parse_failed')
      expect(outcome[:error_code]).to eq('snapshot_item_limit')
      expect(ExternalFeedSnapshot.where(external_source_id: source_id).where('item_count > 1').count).to eq(0)
      expect(ExternalSource.find(source_id).etag).to eq(etag)
    end

    it 'refuses a new body when the open snapshot cap is full and keeps the stored body' do
      subscribe_feed(feed_xml(1))
      hold_drain
      refresh_feed(feed_xml(page + 1))
      stored = ExternalFeedSnapshot.open.last.body
      stub_const('ExternalBridge::RSS::Limits::SNAPSHOT_OPEN_LIMIT', 1)
      stub_request(:get, feed_url).to_return(status: 200, body: feed_xml(2), headers: { 'ETag' => 'W/"backlog"' })
      outcome = refresh_feed_without_stub

      expect(outcome[:outcome]).to eq('snapshot_backlog')
      expect(ExternalFeedSnapshot.open.last.body).to eq(stored)
    end
  end

  def page
    ExternalBridge::RSS::Limits::MAX_ITEMS
  end

  def subscribe_feed(body)
    stub_request(:get, feed_url).to_return(status: 200, body: body, headers: { 'ETag' => 'W/"one"', 'Last-Modified' => 'Thu, 02 Jan 2020 03:04:05 GMT' })
    described_class_subscribe(user, body)
  end

  def described_class_subscribe(subscriber, _body)
    ExternalBridge::RSS::Subscribe.new.call(user: subscriber, url: feed_url)
  end

  def refresh_feed(body, subscriber: user)
    stub_request(:get, feed_url).to_return(status: 200, body: body, headers: { 'ETag' => "W/\"#{body.bytesize}\"" })
    refresh_feed_without_stub(subscriber)
  end

  def refresh_feed_without_stub(subscriber = user)
    ExternalBridge::RSS::RefreshSource.new.call(source_id, subscription_id: ExternalSubscription.find_by!(user_id: subscriber.id).id)
  end

  def refresh_without_http
    ExternalBridge::RSS::FeedSnapshotDrainWorker.new.perform(source_id)
  end

  def source_id
    ExternalSource.find_by!(canonical_key: feed_url).id
  end

  def projections_for(subscriber)
    ExternalStatusProjection.where(user_id: subscriber.id)
  end

  def projection_guids(subscriber)
    projections_for(subscriber).includes(:external_resource).map { |row| row.external_resource.title && guid_from_resource(row.external_resource) }
  end

  def guid_from_resource(resource)
    resource.canonical_key[/item:(.+)\z/, 1]
  end

  def resources
    ExternalResource.where(external_source_id: source_id)
  end

  def resource_guids
    resources.order(:id).map { |resource| guid_from_resource(resource) }
  end

  def hold_drain
    allow(ExternalBridge::RSS::FeedSnapshotDrainWorker).to receive(:perform_async).and_return('held')
  end

  def release_drain
    allow(ExternalBridge::RSS::FeedSnapshotDrainWorker).to receive(:perform_async).and_call_original
  end

  def feed_xml(count, order: :newest_first, title_for: nil)
    rss_document(items_xml(count, order: order, title_for: title_for))
  end

  def items_xml(count, order: :newest_first, title_for: nil)
    count.times.map { |index|
      rss_item(
        guid: "guid-#{index}",
        title: title_for ? title_for.call(index) : "T#{index}",
        link: "https://example.com/i/#{index}",
        body: "Body #{index}",
        date: date_for(index, count, order)
      )
    }.join
  end

  def date_for(index, count, order)
    case order
    when :oldest_first then stamp(Time.utc(2024, 1, 1) + index.days)
    when :newest_first then stamp(Time.utc(2024, 1, 1) + (count - index).days)
    when :same then stamp(Time.utc(2024, 3, 1))
    when :missing then ''
    when :irregular then stamp(Time.utc(2024, 1, 1) + ((index * 17) % [count, 1].max).days)
    else stamp(Time.utc(2024, 1, 1) + index.days)
    end
  end

  def stamp(time)
    time.utc.rfc2822
  end

  def rss_kb
    return nil unless File.exist?('/proc/self/status')

    File.read('/proc/self/status')[/VmRSS:\s+(\d+)/, 1]&.to_i
  end

  # Opt-in. A normal run does not touch a fixed path or require /proc.
  def write_measurement(elapsed, rss_before, batches)
    return unless ENV['RSS_SNAPSHOT_MEASURE'] == '1'

    directory = ENV.fetch('RSS_SNAPSHOT_MEASURE_DIR', Dir.tmpdir)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'rss-snapshot-measurements.txt'), <<~TEXT)
      items=81
      elapsed_seconds=#{elapsed.round(3)}
      rss_before_kb=#{rss_before}
      rss_after_kb=#{rss_kb}
      drain_batches=#{batches}
      resources=#{resources.count}
      projections=#{ExternalStatusProjection.where(user_id: user.id).count}
    TEXT
  end
end
