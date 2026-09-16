# frozen_string_literal: true

require 'rails_helper'

# Test-only numbers. Not production defaults.
RSpec.describe FollowImport::AdaptiveRemoteAdvisor do
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

  def fixed_profile(destination: 4, origin: 3)
    FollowImport::RemoteAdmissionProfile.parse(
      {
        version: 1,
        destination: { per_tick_cap: destination },
        origin: { per_tick_cap: origin },
        runtime: {
          mapping_ttl_seconds: 3600,
          max_retry_after_seconds: 120,
          recent_429_cooldown_seconds: 30,
        },
        scan: { max_targets_per_batch: 20, max_windows_per_batch: 4 },
      }
    )
  end

  def runtime(mappings: {})
    state = Object.new
    state.define_singleton_method(:available?) { true }
    state.define_singleton_method(:mapping_for) do |domain|
      origin = mappings[domain]
      next if origin.blank?

      FollowImport::RemoteRuntimeState::Mapping.new(endpoint_origin: origin, observed_at: Time.now.utc)
    end
    state.define_singleton_method(:suppression_for) { |_origin| nil }
    state
  end

  def base_admission(destination: 4, origin: 3, mappings: {})
    FollowImport::RemoteAdmission.new(
      profile: fixed_profile(destination: destination, origin: origin),
      runtime: runtime(mappings: mappings)
    )
  end

  def advisor(admission: nil, state: nil, destination: 4)
    described_class.new(
      admission: admission || base_admission(destination: destination),
      adaptive_profile: adaptive_profile,
      fixed_profile: fixed_profile(destination: destination),
      state: state || FollowImport::AdaptiveRemoteState.new(
        adaptive_profile: adaptive_profile,
        fixed_profile: fixed_profile(destination: destination)
      ).snapshot
    )
  end

  def seed_cap(layer, key, cap)
    writer = FollowImport::AdaptiveRemoteState.new(
      adaptive_profile: adaptive_profile,
      fixed_profile: fixed_profile
    )
    redis_key = layer == :origin ? writer.origin_key(key) : writer.destination_key(key)
    RedisConfiguration.with do |redis|
      redis.set(
        redis_key,
        {
          schema_version: 1,
          current_cap: cap,
          success_credit: 0,
          observed_at: Time.now.utc.iso8601,
          observed_at_unix: Time.now.utc.to_i,
          adaptive_profile_digest: adaptive_profile.digest,
          fixed_profile_digest: fixed_profile.digest,
        }.to_json,
        ex: 120
      )
    end
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

  it 'never changes an actual base deny or admit' do
    policy = advisor(admission: base_admission(destination: 1))
    first = policy.decide(destination_domain: 'remote.example')
    policy.record_admit(first)
    second = policy.decide(destination_domain: 'remote.example')

    expect(first.admit?).to be true
    expect(second.admit?).to be false
    expect(second.reason).to eq 'destination_cap'
  end

  it 'counts would-block among current fixed admits without consuming the hypothetical counter' do
    seed_cap(:destination, 'remote.example', 2)
    policy = advisor

    4.times do
      decision = policy.decide(destination_domain: 'remote.example')
      expect(decision.admit?).to be true
      policy.record_admit(decision)
    end

    stats = policy.stats
    expect(stats['adaptive_shadow_evaluated_current_claim_count']).to eq 4
    expect(stats['adaptive_shadow_would_block_current_claim_count']).to eq 2
    expect(stats['adaptive_shadow_destination_would_block_count']).to eq 2
  end

  it 'does not evaluate local destinations' do
    local = TagManager.instance.normalize_domain(Rails.configuration.x.local_domain)
    policy = advisor

    decision = policy.decide(destination_domain: local)
    policy.record_admit(decision)

    expect(decision.reason).to eq 'local_destination'
    expect(policy.stats['adaptive_shadow_evaluated_current_claim_count']).to eq 0
  end

  it 'evaluates destination only when no origin mapping is present' do
    seed_cap(:destination, 'a.example', 1)
    seed_cap(:origin, 'https://shared.example', 1)
    policy = advisor

    2.times do
      decision = policy.decide(destination_domain: 'a.example')
      policy.record_admit(decision) if decision.admit?
    end

    expect(policy.stats['adaptive_shadow_origin_would_block_count']).to eq 0
    expect(policy.stats['adaptive_shadow_destination_would_block_count']).to eq 1
  end

  it 'evaluates a shared origin cap when a mapping is present' do
    seed_cap(:origin, 'https://shared.example', 1)
    policy = advisor(admission: base_admission(mappings: {
      'a.example' => 'https://shared.example',
      'b.example' => 'https://shared.example',
    }))

    first = policy.decide(destination_domain: 'a.example')
    policy.record_admit(first)
    second = policy.decide(destination_domain: 'b.example')
    policy.record_admit(second)

    expect(first.admit?).to be true
    expect(second.admit?).to be true
    expect(policy.stats['adaptive_shadow_origin_would_block_count']).to eq 1
    expect(policy.stats['adaptive_shadow_would_block_current_claim_count']).to eq 1
  end

  it 'continues the actual admit when the sidecar raises' do
    failing = Object.new
    failing.define_singleton_method(:view_for_destination) { |_domain| raise 'sidecar-boom' }
    failing.define_singleton_method(:view_for_origin) { |_origin| raise 'sidecar-boom' }
    policy = advisor(state: failing)

    decision = policy.decide(destination_domain: 'remote.example')

    expect(decision.admit?).to be true
  end

  it 'does not consult Accept, Reject, Follow Gate, or moderation inputs' do
    allow(Follow).to receive(:exists?)
    allow(FollowRequest).to receive(:exists?)
    allow(FollowImport::ExecutionGate).to receive(:for_account)
    advisor.decide(destination_domain: 'remote.example')

    expect(Follow).not_to have_received(:exists?)
    expect(FollowRequest).not_to have_received(:exists?)
    expect(FollowImport::ExecutionGate).not_to have_received(:for_account)
  end
end
