# frozen_string_literal: true

require 'rails_helper'

describe ActivityPub::DeliveryWorker do
  include RoutingHelper

  subject { described_class.new }

  let(:sender)  { Fabricate(:account) }
  let(:payload) { 'test' }

  before do
    allow_any_instance_of(Account).to receive(:remote_followers_hash).with('https://example.com/api').and_return('somehash')
  end

  describe 'perform' do
    it 'performs a request' do
      stub_request(:post, 'https://example.com/api').to_return(status: 200)
      subject.perform(payload, sender.id, 'https://example.com/api', { 'synchronize_followers' => true })
      expect(a_request(:post, 'https://example.com/api').with(headers: { 'Collection-Synchronization' => "collectionId=\"#{account_followers_url(sender)}\", digest=\"somehash\", url=\"#{account_followers_synchronization_url(sender)}\"" })).to have_been_made.once
    end

    it 'raises when request fails' do
      stub_request(:post, 'https://example.com/api').to_return(status: 500)
      expect { subject.perform(payload, sender.id, 'https://example.com/api') }.to raise_error Mastodon::UnexpectedResponseError
    end
  end

  describe 'delivery tracking' do
    let(:tracking) { { 'type' => 'follow_import_target', 'id' => 5 } }

    it 'notifies tracking of successful delivery' do
      stub_request(:post, 'https://example.com/api').to_return(status: 200)
      expect(ActivityPub::DeliveryTracking).to receive(:delivered).with(tracking)
      subject.perform(payload, sender.id, 'https://example.com/api', { 'delivery_tracking' => tracking })
    end

    it 'does not notify tracking on a retryable failure (delivery may still succeed)' do
      stub_request(:post, 'https://example.com/api').to_return(status: 500)
      expect(ActivityPub::DeliveryTracking).not_to receive(:delivered)
      expect { subject.perform(payload, sender.id, 'https://example.com/api', { 'delivery_tracking' => tracking }) }.to raise_error Mastodon::UnexpectedResponseError
    end

    it 'does not notify tracking when the inbox is unavailable and delivery is skipped' do
      allow(DeliveryFailureTracker).to receive(:available?).with('https://example.com/api').and_return(false)
      expect(ActivityPub::DeliveryTracking).not_to receive(:delivered)
      subject.perform(payload, sender.id, 'https://example.com/api', { 'delivery_tracking' => tracking })
    end

    it 'notifies tracking of terminal failure once retries are exhausted' do
      expect(ActivityPub::DeliveryTracking).to receive(:failed).with(tracking)
      msg = { 'args' => [payload, sender.id, 'https://example.com/api', { 'delivery_tracking' => tracking }] }
      described_class.sidekiq_retries_exhausted_block.call(msg)
    end

    it 'tolerates a retries-exhausted message with no tracking metadata' do
      expect(ActivityPub::DeliveryTracking).not_to receive(:failed)
      msg = { 'args' => [payload, sender.id, 'https://example.com/api', {}] }
      expect { described_class.sidekiq_retries_exhausted_block.call(msg) }.not_to raise_error
    end
  end

  describe 'follow-import transport observation' do
    let(:batch) do
      FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                                target_count: 1, resolved_target_count: 0, unresolved_target_count: 1)
    end
    let(:import_target) do
      batch.targets.create!(target_key_hash: 'key', destination_domain: 'example.com', position: 0)
    end
    let(:tracking) { { 'type' => 'follow_import_target', 'id' => import_target.id } }
    let(:inbox_url) { 'https://cdn.example.social:8443/users/bob/inbox' }

    before do
      allow_any_instance_of(Account).to receive(:remote_followers_hash).and_return('somehash')
    end

    it 'records a 2xx delivery observation with endpoint origin and no inbox path' do
      stub_request(:post, inbox_url).to_return(status: 200)

      expect {
        subject.perform(payload, sender.id, inbox_url, { 'delivery_tracking' => tracking })
      }.to change(FollowImportTransportObservation, :count).by(1)

      observation = FollowImportTransportObservation.last
      expect(observation.phase).to eq 'activitypub_delivery'
      expect(observation.outcome).to eq 'http_success'
      expect(observation.http_status).to eq 200
      expect(observation.destination_domain).to eq 'example.com'
      expect(observation.endpoint_origin).to eq 'https://cdn.example.social:8443'
      expect(observation.target_id).to eq import_target.id
      expect(observation.batch_id).to eq batch.id
      expect(observation.metadata['performed']).to be true
    end

    it 'records a retryable HTTP error and still raises so Sidekiq retries' do
      stub_request(:post, inbox_url).to_return(status: 429, headers: { 'Retry-After' => '30' })

      expect {
        subject.perform(payload, sender.id, inbox_url, { 'delivery_tracking' => tracking })
      }.to raise_error(Mastodon::UnexpectedResponseError)

      observation = FollowImportTransportObservation.last
      expect(observation.outcome).to eq 'http_retryable'
      expect(observation.http_status).to eq 429
      expect(observation.retry_after_seconds).to eq 30
      expect(observation.error_class).to eq 'Mastodon::UnexpectedResponseError'
    end

    it 'keeps the status of a terminal unsalvageable HTTP response and does not treat performed as success' do
      stub_request(:post, inbox_url).to_return(status: 404)

      expect {
        subject.perform(payload, sender.id, inbox_url, { 'delivery_tracking' => tracking })
      }.not_to raise_error

      observation = FollowImportTransportObservation.last
      expect(observation.outcome).to eq 'http_unsalvageable'
      expect(observation.http_status).to eq 404
      expect(observation.metadata['performed']).to be true
    end

    it 'records a timeout observation and preserves the existing raise' do
      stub_request(:post, inbox_url).to_raise(HTTP::TimeoutError.new('read timed out'))

      expect {
        subject.perform(payload, sender.id, inbox_url, { 'delivery_tracking' => tracking })
      }.to raise_error(HTTP::TimeoutError)

      observation = FollowImportTransportObservation.last
      expect(observation.outcome).to eq 'timeout'
      expect(observation.error_class).to eq 'HTTP::TimeoutError'
      expect(observation.http_status).to be_nil
    end

    it 'records a connection-failure observation and preserves the existing raise' do
      stub_request(:post, inbox_url).to_raise(HTTP::ConnectionError.new('connection refused'))

      expect {
        subject.perform(payload, sender.id, inbox_url, { 'delivery_tracking' => tracking })
      }.to raise_error(HTTP::ConnectionError)

      observation = FollowImportTransportObservation.last
      expect(observation.outcome).to eq 'connection_failure'
      expect(observation.error_class).to eq 'HTTP::ConnectionError'
    end

    it 'does not create telemetry for ordinary non-follow-import deliveries' do
      stub_request(:post, 'https://example.com/api').to_return(status: 200)

      expect {
        subject.perform(payload, sender.id, 'https://example.com/api')
      }.not_to change(FollowImportTransportObservation, :count)
    end

    it 'does not change a successful delivery when telemetry insert fails' do
      stub_request(:post, inbox_url).to_return(status: 200)
      allow(FollowImportTransportObservation).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')
      expect(ActivityPub::DeliveryTracking).to receive(:delivered).with(tracking)

      expect {
        subject.perform(payload, sender.id, inbox_url, { 'delivery_tracking' => tracking })
      }.not_to raise_error
    end

    it 'still raises a retryable HTTP error when telemetry insert fails' do
      stub_request(:post, inbox_url).to_return(status: 500)
      allow(FollowImportTransportObservation).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect {
        subject.perform(payload, sender.id, inbox_url, { 'delivery_tracking' => tracking })
      }.to raise_error(Mastodon::UnexpectedResponseError)
    end
  end
end
