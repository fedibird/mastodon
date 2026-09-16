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

  # Deterministic interleaving of GET/compare/SET. If write_suppression
  # reads then writes from Ruby, both GETs see nil and the shorter SET
  # is applied last. The Lua path never calls GET/SET for suppression,
  # so the longer honor_until wins.
  class InterleavingRedis
    def initialize(inner)
      @inner = inner
      @mutex = Mutex.new
      @cv = ConditionVariable.new
      @gets = 0
      @pending_sets = []
      @applied = false
    end

    def get(key)
      value = @inner.get(key)
      return value unless suppression_key?(key)

      @mutex.synchronize do
        @gets += 1
        @cv.broadcast
        @cv.wait(@mutex) while @gets < 2
      end
      value
    end

    def set(key, value, **opts)
      return @inner.set(key, value, **opts) unless suppression_key?(key)

      @mutex.synchronize do
        @pending_sets << [key, value, opts]
        @cv.broadcast
        @cv.wait(@mutex) while @pending_sets.size < 2 && !@applied
        apply_sets_shorter_last unless @applied
        @cv.broadcast
      end
      'OK'
    end

    def eval(*args, **kwargs)
      @inner.eval(*args, **kwargs)
    end

    def method_missing(name, *args, **kwargs, &block)
      @inner.public_send(name, *args, **kwargs, &block)
    end

    def respond_to_missing?(name, include_private = false)
      @inner.respond_to?(name, include_private)
    end

    private

    def suppression_key?(key)
      key.to_s.include?(':suppression:')
    end

    def apply_sets_shorter_last
      ordered = @pending_sets.sort_by do |_key, value, _opts|
        Time.iso8601(JSON.parse(value).fetch('honor_until'))
      end
      ordered.reverse_each do |key, value, opts|
        @inner.set(key, value, **opts)
      end
      @applied = true
    end
  end

  it 'does not let a shorter concurrent writer overwrite a longer suppression' do
    now = Time.utc(2026, 9, 16, 12, 0, 0)
    longer = state(now: now, max_retry: 120)
    shorter = state(now: now, max_retry: 120)
    wrapper = InterleavingRedis.new(longer.redis)
    allow(longer).to receive(:redis).and_return(wrapper)
    allow(shorter).to receive(:redis).and_return(wrapper)

    threads = [
      Thread.new do
        longer.observe(
          destination_domain: 'a.example',
          inbox_url: 'https://shared.example/inbox',
          http_status: 429,
          retry_after_seconds: 120,
          request_reached: true
        )
      end,
      Thread.new do
        shorter.observe(
          destination_domain: 'a.example',
          inbox_url: 'https://shared.example/inbox',
          http_status: 429,
          retry_after_seconds: 20,
          request_reached: true
        )
      end,
    ]
    threads.each(&:join)

    suppression = state(now: now).suppression_for('https://shared.example')
    expect(suppression.honor_until).to eq now + 120
    expect(suppression.reason).to eq 'retry_after'
  end
end
