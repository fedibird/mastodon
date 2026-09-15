# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::LocalLoadProfile do
  def parse(payload)
    described_class.parse(payload)
  end

  it 'treats a blank profile as unconfigured' do
    profile = parse(nil)

    expect(profile.configured?).to be false
    expect(profile.source).to eq 'unconfigured'
    expect(profile.enforcement_capable?).to be false
  end

  it 'treats an empty string as unconfigured' do
    expect(parse('').source).to eq 'unconfigured'
  end

  it 'treats malformed JSON as invalid without raising' do
    profile = parse('{not json')

    expect(profile.invalid?).to be true
    expect(profile.source).to eq 'invalid'
    expect(profile.error).to be_present
  end

  it 'classifies JSON scalars and arrays as invalid without raising' do
    %w("hello" 123 [] null).each do |raw|
      profile = parse(raw)

      expect(profile.invalid?).to be(true), "expected #{raw.inspect} to be invalid"
      expect { described_class.parse(raw) }.not_to raise_error
    end
  end

  it 'classifies a Ruby non-object payload as invalid without raising' do
    [123, [], 'hello'].each do |raw|
      profile = parse(raw)

      expect(profile.invalid?).to be(true), "expected #{raw.inspect} to be invalid"
    end
  end

  it 'rejects unknown keys' do
    profile = parse('{"version":1,"extra":true}')

    expect(profile.invalid?).to be true
  end

  it 'rejects a stronger level that recommends more budget than a weaker one' do
    profile = parse(
      'version' => 1,
      'levels' => {
        'busy' => { 'budget_percent' => 10, 'push' => { 'latency' => 1 } },
        'heavy' => { 'budget_percent' => 50, 'push' => { 'latency' => 2 } },
      }
    )

    expect(profile.invalid?).to be true
  end

  it 'rejects inverted thresholds for the same signal' do
    profile = parse(
      'version' => 1,
      'levels' => {
        'busy' => { 'budget_percent' => 50, 'push' => { 'latency' => 10 } },
        'heavy' => { 'budget_percent' => 10, 'push' => { 'latency' => 2 } },
      }
    )

    expect(profile.invalid?).to be true
  end

  it 'accepts a valid v1 injected profile and exposes a digest' do
    profile = parse(
      'version' => 1,
      'levels' => {
        'busy' => { 'budget_percent' => 50, 'push' => { 'latency' => 2 }, 'retry_size' => 10 },
        'overloaded' => { 'budget_percent' => 0, 'push' => { 'latency' => 20 } },
      },
      'capacity' => { 'per_push_thread' => 3, 'max_tick_claims' => 40 }
    )

    expect(profile.configured?).to be true
    expect(profile.version).to eq 1
    expect(profile.enforcement_capable?).to be false
    expect(profile.level('busy').budget_percent).to eq 50
    expect(profile.capacity.per_push_thread).to eq 3
    expect(profile.digest).to be_present
  end

  it 'rejects a v1 profile that includes fallback' do
    profile = parse(
      'version' => 1,
      'fallback' => { 'budget_percent' => 10 }
    )

    expect(profile.invalid?).to be true
  end

  it 'requires fallback on a v2 profile' do
    profile = parse('version' => 2)

    expect(profile.invalid?).to be true
    expect(profile.enforcement_capable?).to be false
  end

  it 'accepts a v2 enforcement-capable profile and includes fallback in the digest' do
    without_levels = parse('version' => 2, 'fallback' => { 'budget_percent' => 25 })
    same = parse('version' => 2, 'fallback' => { 'budget_percent' => 25 })
    other = parse('version' => 2, 'fallback' => { 'budget_percent' => 0 })

    expect(without_levels.enforcement_capable?).to be true
    expect(without_levels.fallback.budget_percent).to eq 25
    expect(without_levels.fallback_budget(20)).to eq 5
    expect(without_levels.digest).to eq same.digest
    expect(without_levels.digest).not_to eq other.digest
  end

  it 'reads the canonical ENV and ignores the deprecated alias when both exist' do
    ClimateControl.modify(
      FOLLOW_IMPORT_LOCAL_LOAD_PROFILE: '{"version":2,"fallback":{"budget_percent":10}}',
      FOLLOW_IMPORT_LOCAL_LOAD_SHADOW_PROFILE: '{"version":1}'
    ) do
      profile = described_class.from_env

      expect(profile.configured?).to be true
      expect(profile.source).to eq 'env'
      expect(profile.version).to eq 2
      expect(profile.fallback.budget_percent).to eq 10
    end
  end

  it 'uses the deprecated shadow ENV only when the canonical variable is absent' do
    ClimateControl.modify FOLLOW_IMPORT_LOCAL_LOAD_SHADOW_PROFILE: '{"version":1}' do
      profile = described_class.from_env

      expect(profile.configured?).to be true
      expect(profile.source).to eq 'env_legacy'
      expect(profile.version).to eq 1
      expect(profile.enforcement_capable?).to be false
    end
  end

  it 'does not invent a profile when no ENV is set' do
    expect(ENV).not_to have_key(described_class::ENV_KEY)
    expect(ENV).not_to have_key(described_class::LEGACY_ENV_KEY)

    profile = described_class.from_env

    expect(profile.source).to eq 'unconfigured'
  end
end
