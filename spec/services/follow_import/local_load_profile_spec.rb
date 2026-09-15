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
  end

  it 'treats malformed JSON as invalid without raising' do
    profile = parse('{not json')

    expect(profile.invalid?).to be true
    expect(profile.source).to eq 'invalid'
    expect(profile.error).to be_present
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

  it 'accepts a valid injected profile and exposes a digest' do
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
    expect(profile.level('busy').budget_percent).to eq 50
    expect(profile.capacity.per_push_thread).to eq 3
    expect(profile.digest).to be_present
  end

  it 'reads the operational ENV JSON without inventing defaults' do
    ClimateControl.modify FOLLOW_IMPORT_LOCAL_LOAD_SHADOW_PROFILE: '{"version":1}' do
      profile = described_class.from_env

      expect(profile.configured?).to be true
      expect(profile.source).to eq 'env'
      expect(profile.levels).to eq({})
    end
  end
end
