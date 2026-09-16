# frozen_string_literal: true

require 'rails_helper'

# Test-only AIMD / TTL numbers. Not production defaults.
RSpec.describe FollowImport::AdaptiveRemoteState do
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

  def fixed_profile
    FollowImport::RemoteAdmissionProfile.parse(
      {
        version: 1,
        destination: { per_tick_cap: 4 },
        origin: { per_tick_cap: 3 },
        runtime: {
          mapping_ttl_seconds: 3600,
          max_retry_after_seconds: 120,
          recent_429_cooldown_seconds: 30,
        },
        scan: { max_targets_per_batch: 20, max_windows_per_batch: 4 },
      }
    )
  end

  def state(now: Time.utc(2026, 9, 16, 12, 0, 0))
    described_class.new(adaptive_profile: adaptive_profile, fixed_profile: fixed_profile, now: now)
  end

  around do |example|
    RedisConfiguration.with do |redis|
      keys = redis.keys('follow_import:remote_adaptive:v1:*')
      redis.del(*keys) if keys.any?
    end
    example.run
    RedisConfiguration.with do |redis|
      keys = redis.keys('follow_import:remote_adaptive:v1:*')
      redis.del(*keys) if keys.any?
    end
  end

  it 'starts missing state at the conservative initial cap' do
    view = state.view_for_destination('remote.example')

    expect(view.current_cap).to eq 2
    expect(view.source).to eq 'initial'
  end

  it 'sets a TTL so old remote state does not live forever' do
    writer = state
    writer.apply(destination_domain: 'a.example', endpoint_origin: 'https://shared.example', event: 'success')

    ttl = RedisConfiguration.with { |redis| redis.ttl(writer.destination_key('a.example')) }
    expect(ttl).to be > 0
    expect(ttl).to be <= 120
  end

  it 'falls back safely from a corrupt payload' do
    writer = state
    RedisConfiguration.with do |redis|
      redis.set(writer.destination_key('a.example'), 'not-json', ex: 120)
    end

    view = state.view_for_destination('a.example')
    expect(view.current_cap).to eq 2
    expect(view.source).to eq 'corrupt_reset'
  end

  it 'does not raise into the business path when Redis is unavailable' do
    writer = state
    allow(writer).to receive(:redis).and_raise(Redis::BaseError, 'down')

    expect { writer.view_for_destination('a.example') }.not_to raise_error
    expect(writer.view_for_destination('a.example').source).to eq 'runtime_unavailable'
    expect(writer.available?).to be false
    expect do
      writer.apply(destination_domain: 'a.example', endpoint_origin: nil, event: 'failure')
    end.not_to raise_error
  end

  it 'does not persist a synthetic unknown destination' do
    writer = state
    result = writer.apply(destination_domain: nil, endpoint_origin: 'https://shared.example', event: 'success')

    expect(result.origin.written).to be true
    keys = RedisConfiguration.with { |redis| redis.keys('follow_import:remote_adaptive:v1:destination:*') }
    expect(keys).to be_empty
  end

  it 'updates destination and origin independently' do
    writer = state
    writer.apply(destination_domain: 'a.example', endpoint_origin: 'https://shared.example', event: 'success')
    writer.apply(destination_domain: 'a.example', endpoint_origin: nil, event: 'success')

    dest = state.view_for_destination('a.example')
    origin = state.view_for_origin('https://shared.example')
    expect(dest.current_cap).to eq 3
    expect(origin.current_cap).to eq 2
    expect(origin.success_credit).to eq 1
  end

  it 'shares origin state across destination domains mapped to one origin' do
    writer = state
    writer.apply(destination_domain: 'a.example', endpoint_origin: 'https://shared.example', event: 'rate_limit')
    writer.apply(destination_domain: 'b.example', endpoint_origin: 'https://shared.example', event: 'failure')

    expect(state.view_for_destination('a.example').current_cap).to eq 1
    expect(state.view_for_destination('b.example').current_cap).to eq 1
    expect(state.view_for_origin('https://shared.example').current_cap).to eq 1
  end

  it 'applies concurrent successes atomically so events are not lost' do
    now = Time.utc(2026, 9, 16, 12, 0, 0)
    threads = 20.times.map do
      Thread.new do
        described_class.new(adaptive_profile: adaptive_profile, fixed_profile: fixed_profile, now: now).apply(
          destination_domain: 'hot.example',
          endpoint_origin: nil,
          event: 'success'
        )
      end
    end
    threads.each(&:join)

    view = state(now: now).view_for_destination('hot.example')
    expect(view.current_cap).to eq 4
    expect(view.success_credit).to eq 0
  end

  it 'does not perform a non-atomic GET/SET overwrite on apply' do
    writer = state
    redis = writer.redis
    allow(writer).to receive(:redis).and_return(redis)
    expect(redis).not_to receive(:set)
    expect(redis).to receive(:eval).and_call_original

    writer.apply(destination_domain: 'a.example', endpoint_origin: nil, event: 'failure')
  end

  it 'never stores an inbox path on the origin key' do
    writer = state
    writer.apply(
      destination_domain: 'a.example',
      endpoint_origin: FollowImport::EndpointOrigin.from_url('https://shared.example/users/bob/inbox?x=1'),
      event: 'success'
    )

    keys = RedisConfiguration.with { |redis| redis.keys('follow_import:remote_adaptive:v1:origin:*') }
    expect(keys.join).to eq 'follow_import:remote_adaptive:v1:origin:https://shared.example'
    expect(keys.join).not_to include('inbox')
  end
end
