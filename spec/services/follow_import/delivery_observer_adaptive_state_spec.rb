# frozen_string_literal: true

require 'rails_helper'

# Test-only numbers. Not production defaults.
RSpec.describe FollowImport::DeliveryObserver, 'adaptive remote state' do
  def fixed_profile
    FollowImport::RemoteAdmissionProfile.parse(
      {
        version: 1,
        destination: { per_tick_cap: 4 },
        origin: { per_tick_cap: 3 },
        runtime: {
          mapping_ttl_seconds: 3600,
          max_retry_after_seconds: 90,
          recent_429_cooldown_seconds: 40,
        },
        scan: { max_targets_per_batch: 20, max_windows_per_batch: 4 },
      }
    )
  end

  def adaptive_profile
    FollowImport::AdaptiveRemoteProfile.parse(
      {
        version: 1,
        destination: {
          initial_cap: 2,
          min_cap: 1,
          additive_step: 1,
          successes_per_increase: 2,
          failure_multiplier_percent: 50,
          rate_limit_multiplier_percent: 25,
        },
        origin: {
          initial_cap: 2,
          min_cap: 1,
          additive_step: 1,
          successes_per_increase: 2,
          failure_multiplier_percent: 50,
          rate_limit_multiplier_percent: 25,
        },
        runtime: { stale_after_seconds: 60, state_ttl_seconds: 120 },
      }
    )
  end

  def target_row(domain: 'a.example')
    batch = FollowImportBatch.create!(
      subject: Fabricate(:moderation_subject),
      imported_at: Time.now.utc,
      mode: :merge,
      target_count: 1,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
    batch.targets.create!(
      target_key_hash: "obs-#{SecureRandom.hex(4)}",
      position: 0,
      destination_domain: domain
    )
  end

  def response(status)
    instance_double(HTTP::Response, code: status, headers: {})
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
      error: attrs[:error],
      skip_reason: attrs[:skip_reason],
      performed: true
    )
  end

  around do |example|
    RedisConfiguration.with do |redis|
      keys = redis.keys('follow_import:remote_adaptive:v1:*') + redis.keys('follow_import:remote_admission:v1:*')
      redis.del(*keys) if keys.any?
    end
    example.run
    RedisConfiguration.with do |redis|
      keys = redis.keys('follow_import:remote_adaptive:v1:*') + redis.keys('follow_import:remote_admission:v1:*')
      redis.del(*keys) if keys.any?
    end
  end

  before do
    allow(FollowImport::RemoteAdmissionProfile).to receive(:from_env).and_return(fixed_profile)
    allow(FollowImport::AdaptiveRemoteProfile).to receive(:from_env).and_return(adaptive_profile)
    allow(FollowImport::ExecutionPolicy).to receive(:remote_adaptive_shadow_enabled?).and_return(true)
  end

  it 'writes destination and origin adaptive state from an actual HTTP 2xx' do
    target = target_row
    record(target, response: response(200))

    dest = FollowImport::AdaptiveRemoteState.new(adaptive_profile: adaptive_profile, fixed_profile: fixed_profile)
                                            .view_for_destination('a.example')
    origin = FollowImport::AdaptiveRemoteState.new(adaptive_profile: adaptive_profile, fixed_profile: fixed_profile)
                                              .view_for_origin('https://shared.example')
    observation = FollowImportTransportObservation.last

    expect(dest.success_credit).to eq 1
    expect(origin.success_credit).to eq 1
    expect(observation.metadata['adaptive_event']).to eq 'success'
    expect(observation.metadata['adaptive_state_write_success']).to be true
    expect(observation.metadata['adaptive_destination_cap_after']).to eq 2
    expect(observation.endpoint_origin).not_to include('inbox')
  end

  it 'decreases on 5xx / timeout and more strongly on 429' do
    first = target_row
    record(first, response: response(503))
    after_5xx = FollowImport::AdaptiveRemoteState.new(adaptive_profile: adaptive_profile, fixed_profile: fixed_profile)
                                                 .view_for_destination('a.example')
    second = target_row
    record(second, response: response(429))
    after_429 = FollowImport::AdaptiveRemoteState.new(adaptive_profile: adaptive_profile, fixed_profile: fixed_profile)
                                                 .view_for_destination('a.example')

    expect(after_5xx.current_cap).to eq 1
    expect(after_429.current_cap).to eq 1
  end

  it 'does not update adaptive state for Stoplight-before-request' do
    target = target_row
    record(target, response: nil, request_started_at: nil, error: Stoplight::Error::RedLight.new('inbox'), skip_reason: 'circuit_or_stoplight_interruption')

    view = FollowImport::AdaptiveRemoteState.new(adaptive_profile: adaptive_profile, fixed_profile: fixed_profile)
                                            .view_for_destination('a.example')
    expect(view.source).to eq 'initial'
    expect(FollowImportTransportObservation.last.metadata['adaptive_event']).to eq 'neutral'
    expect(FollowImportTransportObservation.last.metadata['adaptive_state_write_success']).to be false
  end

  it 'does not fail delivery when adaptive Redis writes fail' do
    target = target_row
    allow_any_instance_of(FollowImport::AdaptiveRemoteState).to receive(:apply).and_raise(Redis::BaseError, 'down')

    expect { record(target, response: response(200)) }.not_to raise_error
    expect(FollowImportTransportObservation.last.target_id).to eq target.id
    expect(FollowImportTransportObservation.last.metadata['adaptive_state_write_success']).to be false
  end

  it 'does not write adaptive state when the flag is off' do
    allow(FollowImport::ExecutionPolicy).to receive(:remote_adaptive_shadow_enabled?).and_return(false)
    target = target_row
    record(target, response: response(200))

    keys = RedisConfiguration.with { |redis| redis.keys('follow_import:remote_adaptive:v1:*') }
    expect(keys).to be_empty
    expect(FollowImportTransportObservation.last.metadata).not_to have_key('adaptive_event')
  end
end
