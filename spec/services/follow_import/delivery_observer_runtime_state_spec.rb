# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::DeliveryObserver, 'remote runtime state' do
  def profile
    FollowImport::RemoteAdmissionProfile.parse(
      {
        version: 1,
        destination: { per_tick_cap: 3 },
        origin: { per_tick_cap: 2 },
        runtime: {
          mapping_ttl_seconds: 3600,
          max_retry_after_seconds: 90,
          recent_429_cooldown_seconds: 40,
        },
        scan: { max_targets_per_batch: 20, max_windows_per_batch: 4 },
      }
    )
  end

  def target_row
    batch = FollowImportBatch.create!(
      subject: Fabricate(:moderation_subject),
      imported_at: Time.now.utc,
      mode: :merge,
      target_count: 1,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
    batch.targets.create!(
      target_key_hash: 'obs-1',
      position: 0,
      destination_domain: 'a.example'
    )
  end

  def response(status:, retry_after: nil)
    headers = {}
    headers['Retry-After'] = retry_after unless retry_after.nil?
    instance_double(HTTP::Response, code: status, headers: headers)
  end

  def record(target, **attrs)
    described_class.record_attempt(
      options: { 'delivery_tracking' => { 'type' => 'follow_import_target', 'id' => target.id } },
      inbox_url: attrs.fetch(:inbox_url, 'https://shared.example/users/bob/inbox'),
      sidekiq_queue: 'push',
      sidekiq_job_id: 'jid',
      worker_started_at: Time.now.utc,
      request_started_at: attrs.fetch(:request_started_at, Time.now.utc),
      request_finished_at: Time.now.utc,
      response: attrs[:response],
      error: nil,
      skip_reason: nil,
      performed: true
    )
  end

  around do |example|
    RedisConfiguration.with do |redis|
      keys = redis.keys('follow_import:remote_admission:v1:*')
      redis.del(*keys) if keys.any?
    end
    example.run
    RedisConfiguration.with do |redis|
      keys = redis.keys('follow_import:remote_admission:v1:*')
      redis.del(*keys) if keys.any?
    end
  end

  before do
    allow(FollowImport::RemoteAdmissionProfile).to receive(:from_env).and_return(profile)
  end

  it 'writes mapping from an actual HTTP attempt without storing the inbox path' do
    target = target_row
    record(target, response: response(status: 200))

    mapping = FollowImport::RemoteRuntimeState.new(profile: profile).mapping_for('a.example')
    expect(mapping.endpoint_origin).to eq 'https://shared.example'
    expect(FollowImportTransportObservation.last.metadata['remote_runtime_state_written']).to be true
  end

  it 'parses HTTP-date Retry-After through the existing helper' do
    target = target_row
    stamp = 45.seconds.from_now.httpdate
    record(target, response: response(status: 429, retry_after: stamp))

    suppression = FollowImport::RemoteRuntimeState.new(profile: profile).suppression_for('https://shared.example')
    expect(suppression.reason).to eq 'retry_after'
    expect(suppression.honor_until).to be > Time.now.utc
  end

  it 'does not write Retry-After suppression for a malformed header and uses recent-429 instead' do
    target = target_row
    record(target, response: response(status: 429, retry_after: 'not-a-date'))

    suppression = FollowImport::RemoteRuntimeState.new(profile: profile).suppression_for('https://shared.example')
    expect(suppression.reason).to eq 'recent_429'
  end

  it 'still records transport history when runtime-state write fails' do
    target = target_row
    allow_any_instance_of(FollowImport::RemoteRuntimeState).to receive(:observe).and_raise(Redis::BaseError, 'down')

    expect { record(target, response: response(status: 200)) }.not_to raise_error
    expect(FollowImportTransportObservation.last).to be_present
    expect(FollowImportTransportObservation.last.target_id).to eq target.id
  end

  it 'does not write runtime state when no HTTP request was sent' do
    target = target_row
    record(target, response: nil, request_started_at: nil)

    expect(FollowImport::RemoteRuntimeState.new(profile: profile).mapping_for('a.example')).to be_nil
  end
end
