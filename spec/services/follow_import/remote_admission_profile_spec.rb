# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::RemoteAdmissionProfile do
  def parse(payload)
    described_class.parse(payload)
  end

  def valid_payload(overrides = {})
    {
      'version' => 1,
      'destination' => { 'per_tick_cap' => 3 },
      'origin' => { 'per_tick_cap' => 2 },
      'runtime' => {
        'mapping_ttl_seconds' => 3600,
        'max_retry_after_seconds' => 120,
        'recent_429_cooldown_seconds' => 30,
      },
      'scan' => {
        'max_targets_per_batch' => 50,
        'max_windows_per_batch' => 8,
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
    ClimateControl.modify FOLLOW_IMPORT_REMOTE_ADMISSION_PROFILE: nil do
      ENV.delete('FOLLOW_IMPORT_REMOTE_ADMISSION_PROFILE')
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
    profile = parse(valid_payload.merge('extra' => true))

    expect(profile.invalid?).to be true
  end

  it 'rejects an unknown schema version' do
    expect(parse(valid_payload.merge('version' => 2)).invalid?).to be true
  end

  it 'rejects zero or negative caps and TTLs' do
    expect(parse(valid_payload.merge('destination' => { 'per_tick_cap' => 0 })).invalid?).to be true
    expect(parse(valid_payload.merge('origin' => { 'per_tick_cap' => -1 })).invalid?).to be true
    expect(parse(valid_payload.merge('runtime' => valid_payload['runtime'].merge('mapping_ttl_seconds' => 0))).invalid?).to be true
  end

  it 'rejects an incomplete profile' do
    payload = valid_payload
    payload.delete('scan')

    expect(parse(payload).invalid?).to be true
  end

  it 'accepts a valid injected profile and exposes a stable digest' do
    profile = parse(valid_payload)
    again = parse(valid_payload)

    expect(profile.configured?).to be true
    expect(profile.version).to eq 1
    expect(profile.destination_per_tick_cap).to eq 3
    expect(profile.origin_per_tick_cap).to eq 2
    expect(profile.digest).to be_present
    expect(profile.digest).to eq again.digest
    expect(profile.source).to eq 'injected'
  end

  it 'does not ship a bundled production numeric default' do
    expect(described_class.unconfigured.destination_per_tick_cap).to be_nil
    expect(described_class.unconfigured.origin_per_tick_cap).to be_nil
  end
end
