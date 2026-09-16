# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::RemoteRuntimeState do
  def profile(**caps)
    FollowImport::RemoteAdmissionProfile.parse(
      {
        version: 1,
        destination: { per_tick_cap: 3 },
        origin: { per_tick_cap: 2 },
        runtime: {
          mapping_ttl_seconds: caps.fetch(:mapping_ttl, 3600),
          max_retry_after_seconds: caps.fetch(:max_retry, 120),
          recent_429_cooldown_seconds: caps.fetch(:cooldown, 30),
        },
        scan: { max_targets_per_batch: 20, max_windows_per_batch: 4 },
      }
    )
  end

  def state(now: Time.now.utc, **caps)
    described_class.new(profile: profile(**caps), now: now)
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

  it 'stores a privacy-safe endpoint origin and not an inbox path' do
    now = Time.utc(2026, 9, 16, 12, 0, 0)
    writer = state(now: now)

    writer.observe(
      destination_domain: 'a.example',
      inbox_url: 'https://shared.example/users/bob/inbox?x=1',
      http_status: 200,
      retry_after_seconds: nil,
      request_reached: true
    )

    mapping = state(now: now).mapping_for('a.example')
    expect(mapping.endpoint_origin).to eq 'https://shared.example'
    expect(mapping.endpoint_origin).not_to include('inbox')
  end

  it 'does not write mapping when no HTTP request reached the request layer' do
    writer = state
    written = writer.observe(
      destination_domain: 'a.example',
      inbox_url: 'https://shared.example/inbox',
      http_status: nil,
      retry_after_seconds: nil,
      request_reached: false
    )

    expect(written).to be false
    expect(state.mapping_for('a.example')).to be_nil
  end

  it 'caps Retry-After at the configured maximum' do
    now = Time.utc(2026, 9, 16, 12, 0, 0)
    writer = state(now: now, max_retry: 60)
    writer.observe(
      destination_domain: 'a.example',
      inbox_url: 'https://shared.example/inbox',
      http_status: 429,
      retry_after_seconds: 600,
      request_reached: true
    )

    suppression = state(now: now).suppression_for('https://shared.example')
    expect(suppression.reason).to eq 'retry_after'
    expect(suppression.honor_until).to eq now + 60
  end

  it 'uses the configured recent-429 cooldown when Retry-After is absent' do
    now = Time.utc(2026, 9, 16, 12, 0, 0)
    writer = state(now: now, cooldown: 45)
    writer.observe(
      destination_domain: 'a.example',
      inbox_url: 'https://shared.example/inbox',
      http_status: 429,
      retry_after_seconds: nil,
      request_reached: true
    )

    suppression = state(now: now).suppression_for('https://shared.example')
    expect(suppression.reason).to eq 'recent_429'
    expect(suppression.honor_until).to eq now + 45
  end

  it 'lets Retry-After take precedence over a 429 cooldown' do
    now = Time.utc(2026, 9, 16, 12, 0, 0)
    writer = state(now: now, max_retry: 20, cooldown: 45)
    writer.observe(
      destination_domain: 'a.example',
      inbox_url: 'https://shared.example/inbox',
      http_status: 429,
      retry_after_seconds: 10,
      request_reached: true
    )

    expect(state(now: now).suppression_for('https://shared.example').reason).to eq 'retry_after'
    expect(state(now: now).suppression_for('https://shared.example').honor_until).to eq now + 10
  end

  it 'does not shorten an existing later honor_until' do
    now = Time.utc(2026, 9, 16, 12, 0, 0)
    first = state(now: now, max_retry: 120)
    first.observe(
      destination_domain: 'a.example',
      inbox_url: 'https://shared.example/inbox',
      http_status: 429,
      retry_after_seconds: 90,
      request_reached: true
    )
    later = state(now: now + 10, max_retry: 120)
    later.observe(
      destination_domain: 'a.example',
      inbox_url: 'https://shared.example/inbox',
      http_status: 429,
      retry_after_seconds: 20,
      request_reached: true
    )

    expect(state(now: now).suppression_for('https://shared.example').honor_until).to eq now + 90
  end

  it 'does not clear suppression because a later success arrived' do
    now = Time.utc(2026, 9, 16, 12, 0, 0)
    writer = state(now: now, max_retry: 120)
    writer.observe(
      destination_domain: 'a.example',
      inbox_url: 'https://shared.example/inbox',
      http_status: 429,
      retry_after_seconds: 60,
      request_reached: true
    )
    state(now: now + 5).observe(
      destination_domain: 'a.example',
      inbox_url: 'https://shared.example/inbox',
      http_status: 200,
      retry_after_seconds: nil,
      request_reached: true
    )

    expect(state(now: now + 5).suppression_for('https://shared.example').honor_until).to eq now + 60
  end

  it 'treats a mapping as unknown after the configured TTL' do
    now = Time.utc(2026, 9, 16, 12, 0, 0)
    state(now: now, mapping_ttl: 30).observe(
      destination_domain: 'a.example',
      inbox_url: 'https://shared.example/inbox',
      http_status: 200,
      retry_after_seconds: nil,
      request_reached: true
    )

    expect(state(now: now + 31, mapping_ttl: 30).mapping_for('a.example')).to be_nil
  end

  it 'does not infer an origin from the acct domain' do
    expect(state.mapping_for('remote.example')).to be_nil
  end

  it 'survives a Redis read failure and reports unavailable' do
    writer = state
    allow(writer).to receive(:redis).and_raise(Redis::BaseError, 'down')

    expect(writer.mapping_for('a.example')).to be_nil
    expect(writer.available?).to be false
  end
end
