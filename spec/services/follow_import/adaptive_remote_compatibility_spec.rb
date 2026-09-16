# frozen_string_literal: true

require 'rails_helper'

# Test-only numbers. Not production defaults.
RSpec.describe FollowImport::AdaptiveRemoteCompatibility do
  def adaptive_payload(dest_initial: 2, dest_min: 1, origin_initial: 2, origin_min: 1)
    {
      'version' => 1,
      'destination' => {
        'initial_cap' => dest_initial,
        'min_cap' => dest_min,
        'additive_step' => 1,
        'successes_per_increase' => 2,
        'failure_multiplier_percent' => 50,
        'rate_limit_multiplier_percent' => 25,
      },
      'origin' => {
        'initial_cap' => origin_initial,
        'min_cap' => origin_min,
        'additive_step' => 1,
        'successes_per_increase' => 2,
        'failure_multiplier_percent' => 50,
        'rate_limit_multiplier_percent' => 25,
      },
      'runtime' => { 'stale_after_seconds' => 60, 'state_ttl_seconds' => 120 },
    }
  end

  def fixed_payload(destination: 4, origin: 3)
    {
      'version' => 1,
      'destination' => { 'per_tick_cap' => destination },
      'origin' => { 'per_tick_cap' => origin },
      'runtime' => {
        'mapping_ttl_seconds' => 3600,
        'max_retry_after_seconds' => 120,
        'recent_429_cooldown_seconds' => 30,
      },
      'scan' => { 'max_targets_per_batch' => 20, 'max_windows_per_batch' => 4 },
    }
  end

  it 'accepts adaptive caps at or below the corresponding fixed caps' do
    adaptive = FollowImport::AdaptiveRemoteProfile.parse(adaptive_payload)
    fixed = FollowImport::RemoteAdmissionProfile.parse(fixed_payload)

    result = described_class.check(adaptive, fixed)

    expect(result.ok).to be true
    expect(described_class.compatible?(adaptive, fixed)).to be true
  end

  it 'rejects adaptive initial or min caps above the matching fixed cap' do
    adaptive = FollowImport::AdaptiveRemoteProfile.parse(adaptive_payload(dest_initial: 5))
    fixed = FollowImport::RemoteAdmissionProfile.parse(fixed_payload(destination: 4))

    result = described_class.check(adaptive, fixed)

    expect(result.ok).to be false
    expect(result.error).to include('destination.initial_cap')
  end

  it 'rejects compatibility when either profile is unconfigured' do
    adaptive = FollowImport::AdaptiveRemoteProfile.parse(adaptive_payload)
    expect(described_class.check(adaptive, FollowImport::RemoteAdmissionProfile.unconfigured).ok).to be false
    expect(described_class.check(FollowImport::AdaptiveRemoteProfile.unconfigured, FollowImport::RemoteAdmissionProfile.parse(fixed_payload)).ok).to be false
  end
end
