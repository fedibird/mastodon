# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'ExternalBridge RSS refresh INFO log' do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/news.xml?format=rss' }
  let(:messages) { [] }
  let(:source) do
    ExternalSource.create!(protocol: 'rss', canonical_key: feed_url, title: 'Secret title', etag: 'W/"secret-etag"', fetched_at: 2.hours.ago, checked_at: 2.hours.ago)
  end
  let(:rss_lines) { messages.select { |line| line.include?('[ExternalBridge::RSS] event=') } }

  before do
    enable_external_bridge_rss!(user, other)
    redis.keys('external_bridge:rss:host:*').each { |key| redis.del(key) }
    allow(Rails.logger).to receive(:info) { |message| messages << message.to_s }
  end

  def subscribe!(account = user, checked_at: 2.hours.ago, **attrs)
    ExternalSubscription.create!(user: account, external_source: source, state: 'active', checked_at: checked_at, **attrs)
  end

  def only_line
    expect(rss_lines.size).to eq 1
    rss_lines.first
  end

  def fields_of(line)
    line.split.drop(1).filter_map { |pair| pair.split('=', 2) if pair.include?('=') }.to_h
  end

  describe Scheduler::ExternalBridgeRSSRefreshScheduler do
    it 'logs feature_disabled once and enqueues nothing' do
      Setting.external_bridge_rss = false
      expect(ExternalBridge::RSS::RefreshSourceWorker).not_to receive(:perform_async)

      described_class.new.perform

      expect(rss_lines.size).to eq 1
      expect(rss_lines.first).to start_with('[ExternalBridge::RSS] event=scheduler outcome=feature_disabled selected=0 enqueued=0 rejected=0 source_ids=- elapsed_ms=')
    end

    it 'logs no_testers when the allowlist is empty' do
      Setting.external_bridge_rss_testers = ''
      subscribe!
      expect(ExternalBridge::RSS::RefreshSourceWorker).not_to receive(:perform_async)

      described_class.new.perform

      expect(fields_of(only_line)).to include('event' => 'scheduler', 'outcome' => 'no_testers', 'selected' => '0')
    end

    it 'treats zero due sources as a normal no_due_sources run' do
      subscribe!(checked_at: 1.minute.ago)
      expect(ExternalBridge::RSS::RefreshSourceWorker).not_to receive(:perform_async)

      expect { described_class.new.perform }.not_to raise_error

      expect(fields_of(only_line)).to include('outcome' => 'no_due_sources', 'selected' => '0', 'enqueued' => '0', 'source_ids' => '-')
    end

    it 'logs the selected source ids and the accepted enqueues on one line' do
      sources = Array.new(3) { |index| ExternalSource.create!(protocol: 'rss', canonical_key: "https://feeds.example/#{index}.xml") }
      sources.each { |row| ExternalSubscription.create!(user: user, external_source: row, state: 'active', checked_at: 2.hours.ago) }
      allow(ExternalBridge::RSS::RefreshSourceWorker).to receive(:perform_async).and_return('jid1')

      described_class.new.perform

      expect(ExternalBridge::RSS::RefreshSourceWorker).to have_received(:perform_async).exactly(3).times
      fields = fields_of(only_line)
      expect(fields).to include('outcome' => 'queued', 'selected' => '3', 'enqueued' => '3', 'rejected' => '0')
      expect(fields['source_ids'].split(',').map(&:to_i)).to match_array(sources.map(&:id))
      expect(only_line).not_to include('jid1')
    end

    it 'caps the selection at the batch limit' do
      stub_const('Scheduler::ExternalBridgeRSSRefreshScheduler::BATCH', 2)
      3.times { |index| ExternalSubscription.create!(user: user, external_source: ExternalSource.create!(protocol: 'rss', canonical_key: "https://feeds.example/#{index}.xml"), state: 'active', checked_at: 2.hours.ago) }
      allow(ExternalBridge::RSS::RefreshSourceWorker).to receive(:perform_async).and_return('jid')

      described_class.new.perform

      expect(fields_of(only_line)).to include('selected' => '2', 'enqueued' => '2')
      expect(fields_of(only_line)['source_ids'].split(',').size).to eq 2
    end

    it 'counts a nil jid as rejected and does not call it an error' do
      subscribe!
      allow(ExternalBridge::RSS::RefreshSourceWorker).to receive(:perform_async).and_return(nil)

      expect { described_class.new.perform }.not_to raise_error

      expect(fields_of(only_line)).to include('outcome' => 'not_enqueued', 'selected' => '1', 'enqueued' => '0', 'rejected' => '1')
    end

    it 'logs a Redis failure once and re-raises it to Sidekiq' do
      subscribe!
      allow(ExternalBridge::RSS::RefreshSourceWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError, 'redis://:password@secret-host:6379')

      expect { described_class.new.perform }.to raise_error(Redis::CannotConnectError)

      line = only_line
      expect(fields_of(line)).to include('outcome' => 'scheduler_error', 'selected' => '1', 'enqueued' => '0', 'error_class' => 'Redis::CannotConnectError')
      expect(line).not_to include('secret-host')
      expect(line).not_to include('password')
    end

    it 'does not enqueue or write because of logging, and survives a logging failure' do
      subscribe!
      allow(Rails.logger).to receive(:info).and_raise(IOError)
      allow(ExternalBridge::RSS::RefreshSourceWorker).to receive(:perform_async).and_return('jid')

      expect { described_class.new.perform }.not_to raise_error
      expect(ExternalBridge::RSS::RefreshSourceWorker).to have_received(:perform_async).once
    end
  end

  describe ExternalBridge::RSS::RefreshSourceWorker do
    let(:body) { rss_document(rss_item(guid: 'secret-guid', title: 'Secret article title', link: 'https://example.com/secret-path', body: 'Secret body text')) }

    def secret_free!(line)
      [feed_url, 'feeds.example', 'Secret', 'secret-guid', 'secret-etag', 'secret-path', user.account.username, user.email].each do |text|
        expect(line).not_to include(text)
      end
    end

    it 'logs skipped_feature_disabled with source_id and no other work' do
      Setting.external_bridge_rss = false

      described_class.new.perform(source.id, 7)

      expect(fields_of(only_line)).to include('event' => 'refresh', 'source_id' => source.id.to_s, 'subscription_id' => '7', 'outcome' => 'skipped_feature_disabled', 'elapsed_ms' => '0')
    end

    it 'logs skipped_source_missing' do
      described_class.new.perform(0)

      expect(fields_of(only_line)).to include('source_id' => '0', 'subscription_id' => '-', 'outcome' => 'skipped_source_missing')
    end

    it 'logs skipped_not_due without a request or a write' do
      subscribe!(checked_at: 1.minute.ago)
      stub_request(:get, feed_url).to_return(status: 200, body: body)
      before_row = source.reload.attributes

      described_class.new.perform(source.id)

      expect(fields_of(only_line)).to include('source_id' => source.id.to_s, 'outcome' => 'skipped_not_due', 'accounted' => '0', 'offered' => '1')
      expect(a_request(:get, feed_url)).not_to have_been_made
      expect(source.reload.attributes).to eq before_row
    end

    it 'logs skipped_no_permitted_subscriptions when no tester subscription remains' do
      Setting.external_bridge_rss_testers = ''
      subscribe!

      described_class.new.perform(source.id)

      expect(fields_of(only_line)).to include('outcome' => 'skipped_no_permitted_subscriptions')
    end

    it 'logs skipped_inactive_subscription for a targeted subscription that cannot run' do
      subscription = subscribe!(state: 'paused')
      subscribe!(other)

      described_class.new.perform(source.id, subscription.id)

      expect(fields_of(only_line)).to include('subscription_id' => subscription.id.to_s, 'outcome' => 'skipped_inactive_subscription', 'offered' => '1')
    end

    it 'logs skipped_lock_busy while another connection holds the source lock' do
      subscribe!
      stub_request(:get, feed_url).to_return(status: 200, body: body)
      holder = ActiveRecord::Base.connection_pool.checkout
      locked = holder.select_value("SELECT pg_try_advisory_lock(810531, #{source.id.to_i})")
      expect(locked == true || locked.to_s == 't').to be true

      described_class.new.perform(source.id)

      expect(fields_of(only_line)).to include('source_id' => source.id.to_s, 'outcome' => 'skipped_lock_busy')
      expect(a_request(:get, feed_url)).not_to have_been_made
    ensure
      if holder
        holder.select_value("SELECT pg_advisory_unlock(810531, #{source.id.to_i})") if source&.id
        ActiveRecord::Base.connection_pool.checkin(holder)
      end
    end

    it 'logs fetched with http_status=200, counters, and no secret text' do
      subscribe!
      stub_request(:get, feed_url).to_return(status: 200, body: body, headers: { 'ETag' => 'W/"fresh-etag"' })

      described_class.new.perform(source.id)

      line = only_line
      expect(fields_of(line)).to include('outcome' => 'fetched', 'http_status' => '200', 'items' => '1', 'accounted' => '1', 'offered' => '0', 'projected_ok' => '1', 'projected_failed' => '0', 'failures' => '0')
      expect(fields_of(line)['elapsed_ms']).to match(/\A\d+\z/)
      expect(line).not_to include('fresh-etag')
      secret_free!(line)
      expect(a_request(:get, feed_url)).to have_been_made.once
    end

    it 'logs a second 200 with unchanged content as fetched, not as an update' do
      subscribe!
      stub_request(:get, feed_url).to_return(status: 200, body: body)
      described_class.new.perform(source.id)
      ExternalSubscription.update_all(checked_at: 2.hours.ago)
      messages.clear

      described_class.new.perform(source.id)

      expect(fields_of(only_line)).to include('outcome' => 'fetched', 'http_status' => '200')
      expect(only_line).not_to match(/updated|changed/)
    end

    it 'logs not_modified with http_status=304 and cached_items' do
      subscribe!
      stub_request(:get, feed_url).to_return(status: 200, body: body, headers: { 'ETag' => 'W/"one"' })
      described_class.new.perform(source.id)
      ExternalSubscription.update_all(checked_at: 2.hours.ago)
      stub_request(:get, feed_url).to_return(status: 304)
      messages.clear

      described_class.new.perform(source.id)

      line = only_line
      expect(fields_of(line)).to include('outcome' => 'not_modified', 'http_status' => '304', 'cached_items' => '1', 'failures' => '0')
      expect(line).not_to include('one')
      expect(source.reload.checked_at).to be_within(5.seconds).of(Time.current)
    end

    it 'logs http_error for a 429 response and still accounts the retry' do
      subscription = subscribe!
      stub_request(:get, feed_url).to_return(status: 429, body: 'slow down', headers: { 'Retry-After' => '60' })

      described_class.new.perform(source.id)

      expect(fields_of(only_line)).to include('outcome' => 'http_error', 'http_status' => '429', 'error_code' => 'http_429', 'failures' => '1')
      expect(subscription.reload.retry_count).to eq 1
      expect(subscription.last_error_code).to eq 'http_429'
    end

    it 'maps a 401 to the fixed authenticated_source_rejected code' do
      subscribe!
      stub_request(:get, feed_url).to_return(status: 401, body: 'no')

      described_class.new.perform(source.id)

      expect(fields_of(only_line)).to include('outcome' => 'http_error', 'http_status' => '401', 'error_code' => 'authenticated_source_rejected')
    end

    it 'logs fetch_failed with the rate_limited code when the host budget is spent' do
      subscription = subscribe!
      allow(ExternalBridge::RSS::HttpClient).to receive(:get).and_raise(ExternalBridge::Error, :rate_limited)

      described_class.new.perform(source.id)

      line = only_line
      expect(fields_of(line)).to include('outcome' => 'fetch_failed', 'error_code' => 'rate_limited', 'failures' => '1')
      expect(line).not_to include('http_status')
      expect(subscription.reload.retry_count).to eq 1
    end

    it 'logs parse_failed with the malformed_feed code' do
      subscription = subscribe!
      stub_request(:get, feed_url).to_return(status: 200, body: '<html>not a feed')

      described_class.new.perform(source.id)

      expect(fields_of(only_line)).to include('outcome' => 'parse_failed', 'http_status' => '200', 'error_code' => 'malformed_feed', 'failures' => '1')
      expect(subscription.reload.last_error_code).to eq 'malformed_feed'
    end

    it 'logs import_failed when materialization raises for a subscriber' do
      subscription = subscribe!
      stub_request(:get, feed_url).to_return(status: 200, body: body)
      allow_any_instance_of(ExternalBridge::RSS::Materialize).to receive(:call).and_raise(StandardError, "boom #{feed_url}")

      described_class.new.perform(source.id)

      line = rss_lines.find { |entry| entry.include?('event=refresh') }
      expect(fields_of(line)).to include('outcome' => 'fetched', 'http_status' => '200', 'failures' => '1')
      expect(subscription.reload.last_error_code).to eq 'import_failed'
      expect(messages.join("\n")).not_to include(feed_url)
    end

    it 'logs unexpected errors once with only the class and re-raises them' do
      subscribe!
      allow(ExternalBridge::RSS::HttpClient).to receive(:get).and_raise(RuntimeError, "boom #{feed_url} secret-token")

      expect { described_class.new.perform(source.id) }.to raise_error(RuntimeError)

      line = only_line
      expect(fields_of(line)).to include('outcome' => 'unexpected_error', 'error_class' => 'RuntimeError', 'source_id' => source.id.to_s)
      expect(line).not_to include('secret-token')
      expect(line).not_to include('feeds.example')
    end

    it 'writes one refresh line per source and carries the targeted subscription id' do
      subscription = subscribe!
      subscribe!(other)
      stub_request(:get, feed_url).to_return(status: 200, body: body)

      described_class.new.perform(source.id, subscription.id)

      expect(rss_lines.size).to eq 1
      expect(fields_of(only_line)).to include('subscription_id' => subscription.id.to_s, 'accounted' => '1', 'offered' => '1')
    end

    it 'does not let a logging failure stop the import' do
      subscribe!
      stub_request(:get, feed_url).to_return(status: 200, body: body)
      allow(Rails.logger).to receive(:info).and_raise(IOError)

      expect { described_class.new.perform(source.id) }.not_to raise_error
      expect(source.external_resources.count).to eq 1
    end
  end

  describe ExternalBridge::RSS::RefreshLog do
    it 'replaces a value that is not a short token' do
      line = described_class.line('refresh', source_id: 1, outcome: 'https://example.com/a?token=x', note: "line\nbreak", ok: 'fetched')

      expect(line).to eq '[ExternalBridge::RSS] event=refresh source_id=1 outcome=- note=- ok=fetched'
    end

    it 'reports an unfamiliar error code as unknown' do
      expect(described_class.code('rate_limited')).to eq 'rate_limited'
      expect(described_class.code('Bad Code https://x')).to eq 'unknown'
    end
  end
end
