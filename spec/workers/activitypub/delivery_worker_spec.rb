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
    let(:enqueued_at) { 2.seconds.ago.utc.change(usec: 0) }
    let(:tracking) { { 'type' => 'follow_import_target', 'id' => import_target.id, 'enqueued_at' => enqueued_at.iso8601(6) } }
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
      expect(observation.enqueued_at).to be_within(1.second).of(enqueued_at)
      expect(observation.queue_wait_ms).to be >= 0
      expect(observation.request_started_at).to be_present
      expect(observation.request_finished_at).to be_present
      expect(observation.request_duration_ms).to be >= 0
      expect(observation.metadata['duration_kind']).to eq 'worker'
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
      expect(observation.request_started_at).to be_present
      expect(observation.request_finished_at).to be_present
      expect(observation.request_duration_ms).to be >= 0
    end

    it 'leaves request timing NULL when availability suppression sends no HTTP request' do
      allow(DeliveryFailureTracker).to receive(:available?).with(inbox_url).and_return(false)

      expect {
        subject.perform(payload, sender.id, inbox_url, { 'delivery_tracking' => tracking })
      }.not_to raise_error

      observation = FollowImportTransportObservation.last
      expect(observation.outcome).to eq 'availability_suppression'
      expect(observation.request_started_at).to be_nil
      expect(observation.request_finished_at).to be_nil
      expect(observation.request_duration_ms).to be_nil
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

  describe 'group delivery observation' do
    let(:author) { Fabricate(:user, admin: true).account }
    let(:group) do
      Fabricate(
        :account,
        username: 'technology',
        domain: 'lemmy.example',
        actor_type: 'Group',
        protocol: :activitypub,
        uri: 'https://lemmy.example/c/technology',
        inbox_url: 'https://lemmy.example/c/technology/inbox'
      )
    end
    let(:status) { Fabricate(:status, account: author, visibility: :public, audience_account: group) }
    let(:inbox_url) { 'https://lemmy.example/c/technology/inbox' }
    let(:observation_key) { PostingContext::GroupFederationObservation.key_for(status.id, group.id) }

    def with_observation
      ClimateControl.modify(
        GROUP_FEDERATION_OBSERVATION_ENABLED: 'true',
        GROUP_FEDERATION_OBSERVATION_AUTHOR_IDS: author.id.to_s
      ) { yield }
    end

    def observed_record
      PostingContext::GroupFederationObservation.read(status.id, group.id)
    end

    before do
      Node.create!(domain: 'lemmy.example', info: { 'software_name' => 'lemmy' })
      with_observation { PostingContext::GroupFederationObservation.prepare(status, author) }
    end

    after do
      RedisConfiguration.with { |redis| redis.del(observation_key) }
    end

    def perform_observed(extra = {})
      subject.perform(payload, sender.id, inbox_url, { 'group_delivery_observation' => observation_key }.merge(extra))
    end

    it 'records HTTP 202 as 2xx without using delivery tracking as that evidence' do
      stub_request(:post, inbox_url).to_return(status: 202)
      expect(ActivityPub::DeliveryTracking).to receive(:delivered).with({ 'type' => 'follow_import_target', 'id' => 5 })

      perform_observed('delivery_tracking' => { 'type' => 'follow_import_target', 'id' => 5 })

      expect(observed_record['last_attempt_outcome']).to eq 'http_success'
      expect(observed_record['last_http_status']).to eq 202
      expect(observed_record['http_2xx_observed']).to be true
      expect(observed_record['http_2xx_at']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
      expect(observed_record['attempt_count']).to eq 1
      expect(observed_record['terminal_failure']).to be false
      expect(observed_record.values.join).not_to include(payload)
    end

    it 'does not treat an unsalvageable 4xx as success' do
      stub_request(:post, inbox_url).to_return(status: 404)

      expect { perform_observed }.not_to raise_error

      expect(observed_record['last_attempt_outcome']).to eq 'http_unsalvageable'
      expect(observed_record['last_http_status']).to eq 404
      expect(observed_record['http_2xx_observed']).to be false
      expect(observed_record['terminal_failure']).to be false
      expect(observed_record['attempt_count']).to eq 1
    end

    it 'keeps a retryable HTTP error and a timeout off the terminal flag' do
      stub_request(:post, inbox_url).to_return(status: 503)

      expect { perform_observed }.to raise_error(Mastodon::UnexpectedResponseError)

      expect(observed_record['last_attempt_outcome']).to eq 'http_retryable'
      expect(observed_record['last_http_status']).to eq 503
      expect(observed_record['terminal_failure']).to be false
      expect(observed_record['attempt_count']).to eq 1

      stub_request(:post, inbox_url).to_raise(HTTP::TimeoutError.new('read timed out'))

      expect { perform_observed }.to raise_error(HTTP::TimeoutError)

      expect(observed_record['last_attempt_outcome']).to eq 'timeout'
      expect(observed_record['terminal_failure']).to be false
      expect(observed_record['attempt_count']).to eq 2
    end

    it 'records terminal failure only after retries are exhausted and keeps earlier 2xx evidence' do
      stub_request(:post, inbox_url).to_return(status: 200)
      perform_observed

      expect(observed_record['last_attempt_outcome']).to eq 'http_success'
      expect(observed_record['last_http_status']).to eq 200
      expect(observed_record['http_2xx_observed']).to be true

      stub_request(:post, inbox_url).to_return(status: 500)

      expect { perform_observed }.to raise_error(Mastodon::UnexpectedResponseError)

      expect(observed_record['http_2xx_observed']).to be true
      expect(observed_record['terminal_failure']).to be false
      expect(observed_record['attempt_count']).to eq 2

      described_class.sidekiq_retries_exhausted_block.call(
        'args' => [payload, sender.id, inbox_url, { 'group_delivery_observation' => observation_key }]
      )

      expect(observed_record['terminal_failure']).to be true
      expect(observed_record['http_2xx_observed']).to be true
      expect(observed_record['http_2xx_at']).to be_present
    end

    it 'records a circuit interruption without counting an HTTP attempt' do
      allow(subject).to receive(:perform_request).and_raise(Stoplight::Error::RedLight)

      expect { perform_observed }.to raise_error(Stoplight::Error::RedLight)

      expect(observed_record['last_attempt_outcome']).to eq 'circuit_interruption'
      expect(observed_record['attempt_count']).to eq 0
      expect(observed_record['last_http_status']).to be_nil
      expect(observed_record['terminal_failure']).to be false
    end

    it 'does not record an HTTP attempt when availability suppression skips the request' do
      allow(DeliveryFailureTracker).to receive(:available?).with(inbox_url).and_return(false)

      expect { perform_observed }.not_to raise_error

      expect(observed_record['last_attempt_outcome']).to eq 'availability_suppression'
      expect(observed_record['attempt_count']).to eq 0
      expect(observed_record['last_http_status']).to be_nil
      expect(observed_record['http_2xx_observed']).to be false
      expect(a_request(:post, inbox_url)).not_to have_been_made
    end

    it 'does not fail a successful or retryable delivery when observation storage raises' do
      allow(RedisConfiguration).to receive(:with).and_raise(Redis::ConnectionError)
      stub_request(:post, inbox_url).to_return(status: 200)

      expect { perform_observed }.not_to raise_error

      stub_request(:post, inbox_url).to_return(status: 500)

      expect { perform_observed }.to raise_error(Mastodon::UnexpectedResponseError)
      allow(RedisConfiguration).to receive(:with).and_call_original
    end

    it 'does not let a later duplicate failure erase 2xx evidence from an earlier attempt' do
      earlier = 2.seconds.ago.utc
      later = Time.now.utc
      success = {
        'outcome' => 'http_success',
        'http_status' => 200,
        'http_attempt' => true,
        'http_2xx' => true,
        'request_started_at' => later.iso8601(6),
        'observed_at' => later.iso8601,
      }
      stale_failure = success.merge(
        'outcome' => 'http_retryable',
        'http_status' => 500,
        'http_2xx' => false,
        'request_started_at' => earlier.iso8601(6),
        'observed_at' => later.iso8601
      )

      PostingContext::GroupFederationObservation.apply_attempt(observation_key, success)
      PostingContext::GroupFederationObservation.apply_attempt(observation_key, stale_failure)

      expect(observed_record['http_2xx_observed']).to be true
      expect(observed_record['last_attempt_outcome']).to eq 'http_success'
      expect(observed_record['last_http_status']).to eq 200
      expect(observed_record['attempt_count']).to eq 2
      expect(observed_record['terminal_failure']).to be false
    end
  end
end
