# frozen_string_literal: true

require 'rails_helper'

# Test-only AIMD numbers. These are fixtures, not production defaults.
RSpec.describe FollowImport::AdaptiveRemoteProfile do
  def parse(payload)
    described_class.parse(payload)
  end

  def valid_payload(overrides = {})
    {
      'version' => 1,
      'destination' => {
        'initial_cap' => 2,
        'min_cap' => 1,
        'additive_step' => 1,
        'successes_per_increase' => 2,
        'failure_multiplier_percent' => 50,
        'rate_limit_multiplier_percent' => 25,
      },
      'origin' => {
        'initial_cap' => 2,
        'min_cap' => 1,
        'additive_step' => 1,
        'successes_per_increase' => 3,
        'failure_multiplier_percent' => 40,
        'rate_limit_multiplier_percent' => 20,
      },
      'runtime' => {
        'stale_after_seconds' => 60,
        'state_ttl_seconds' => 120,
      },
    }.merge(overrides)
  end

  it 'treats a blank profile as unconfigured' do
    profile = parse(nil)

    expect(profile.configured?).to be false
    expect(profile.source).to eq 'unconfigured'
    expect(profile.digest).to be_nil
  end

  it 'treats an empty string as unconfigured' do
    expect(parse('').source).to eq 'unconfigured'
  end

  it 'treats a missing ENV as unconfigured' do
    ClimateControl.modify FOLLOW_IMPORT_REMOTE_ADAPTIVE_PROFILE: nil do
      ENV.delete('FOLLOW_IMPORT_REMOTE_ADAPTIVE_PROFILE')
      expect(described_class.from_env.source).to eq 'unconfigured'
    end
  end

  it 'treats malformed JSON as invalid without raising' do
    profile = parse('{not json')

    expect(profile.invalid?).to be true
    expect(profile.source).to eq 'invalid'
    expect(profile.error).to be_present
  end

  it 'classifies JSON scalars and arrays as invalid without raising' do
    ['"hello"', '123', '[]', 'null'].each do |raw|
      profile = parse(raw)

      expect(profile.invalid?).to be(true), "expected #{raw.inspect} to be invalid"
      expect { described_class.parse(raw) }.not_to raise_error
    end
  end

  it 'rejects unknown keys' do
    expect(parse(valid_payload.merge('extra' => true)).invalid?).to be true
    expect(parse(valid_payload.merge('destination' => valid_payload['destination'].merge('latency_ms' => 1))).invalid?).to be true
  end

  it 'rejects an unknown schema version' do
    expect(parse(valid_payload.merge('version' => 2)).invalid?).to be true
  end

  it 'rejects out-of-range controller parameters' do
    dest = valid_payload['destination']

    expect(parse(valid_payload.merge('destination' => dest.merge('min_cap' => 0))).invalid?).to be true
    expect(parse(valid_payload.merge('destination' => dest.merge('min_cap' => 4, 'initial_cap' => 2))).invalid?).to be true
    expect(parse(valid_payload.merge('destination' => dest.merge('additive_step' => 0))).invalid?).to be true
    expect(parse(valid_payload.merge('destination' => dest.merge('successes_per_increase' => 0))).invalid?).to be true
    expect(parse(valid_payload.merge('destination' => dest.merge('failure_multiplier_percent' => 0))).invalid?).to be true
    expect(parse(valid_payload.merge('destination' => dest.merge('failure_multiplier_percent' => 100))).invalid?).to be true
    expect(parse(valid_payload.merge('destination' => dest.merge('initial_cap' => 1.5))).invalid?).to be true
  end

  it 'rejects a rate-limit decrease weaker than the generic failure decrease' do
    dest = valid_payload['destination'].merge(
      'failure_multiplier_percent' => 40,
      'rate_limit_multiplier_percent' => 50
    )

    expect(parse(valid_payload.merge('destination' => dest)).invalid?).to be true
  end

  it 'rejects stale_after <= 0 and ttl shorter than stale_after' do
    expect(parse(valid_payload.merge('runtime' => { 'stale_after_seconds' => 0, 'state_ttl_seconds' => 10 })).invalid?).to be true
    expect(parse(valid_payload.merge('runtime' => { 'stale_after_seconds' => 60, 'state_ttl_seconds' => 30 })).invalid?).to be true
  end

  it 'accepts a valid injected profile and exposes a deterministic digest' do
    profile = parse(valid_payload)
    again = parse(valid_payload)

    expect(profile.configured?).to be true
    expect(profile.version).to eq 1
    expect(profile.destination.initial_cap).to eq 2
    expect(profile.origin.min_cap).to eq 1
    expect(profile.digest).to be_present
    expect(profile.digest).to eq again.digest
    expect(profile.source).to eq 'injected'
  end

  it 'does not ship a bundled production numeric default' do
    blank = described_class.unconfigured

    expect(blank.destination.initial_cap).to be_nil
    expect(blank.origin.min_cap).to be_nil
    expect(blank.stale_after_seconds).to be_nil
    expect(described_class.const_defined?(:DEFAULT_INITIAL_CAP)).to be false
  end
end
