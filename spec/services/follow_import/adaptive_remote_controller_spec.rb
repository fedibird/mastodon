# frozen_string_literal: true

require 'rails_helper'

# Test-only AIMD coefficients. Not production defaults.
RSpec.describe FollowImport::AdaptiveRemoteController do
  def params(initial: 2, min: 1, step: 1, needed: 2, failure: 50, rate_limit: 25)
    FollowImport::AdaptiveRemoteProfile::Controller.new(
      initial_cap: initial,
      min_cap: min,
      additive_step: step,
      successes_per_increase: needed,
      failure_multiplier_percent: failure,
      rate_limit_multiplier_percent: rate_limit
    )
  end

  def initial(now: Time.utc(2026, 9, 16, 12, 0, 0), ceiling: 4, source: described_class::SOURCE_INITIAL, **opts)
    described_class.initial_view(
      params(**opts),
      now: now,
      adaptive_digest: 'adapt-a',
      fixed_digest: 'fixed-a',
      ceiling: ceiling,
      source: source
    )
  end

  def apply(view, event, now: Time.utc(2026, 9, 16, 12, 0, 1), ceiling: 4, **opts)
    described_class.apply(
      view,
      event,
      params(**opts),
      ceiling: ceiling,
      now: now,
      adaptive_digest: 'adapt-a',
      fixed_digest: 'fixed-a'
    )
  end

  it 'starts unknown / fresh state at initial_cap' do
    view = initial

    expect(view.current_cap).to eq 2
    expect(view.success_credit).to eq 0
    expect(view.source).to eq 'initial'
  end

  it 'accumulates success credit and increases after the required successes' do
    view = initial
    view = apply(view, 'success')
    expect(view.current_cap).to eq 2
    expect(view.success_credit).to eq 1

    view = apply(view, 'success')
    expect(view.current_cap).to eq 3
    expect(view.success_credit).to eq 0
  end

  it 'never increases above the PR F fixed ceiling' do
    view = initial(initial: 3, ceiling: 4)
    10.times { view = apply(view, 'success', ceiling: 4, initial: 3) }

    expect(view.current_cap).to eq 4
  end

  it 'applies a multiplicative decrease on 5xx, timeout, and connection/SSL failure events' do
    view = initial(initial: 4, ceiling: 4)

    expect(apply(view, 'failure', initial: 4, ceiling: 4).current_cap).to eq 2
  end

  it 'applies a stronger multiplicative decrease on 429' do
    view = initial(initial: 4, ceiling: 4)
    failed = apply(view, 'failure', initial: 4, ceiling: 4)
    limited = apply(view, 'rate_limit', initial: 4, ceiling: 4)

    expect(failed.current_cap).to eq 2
    expect(limited.current_cap).to eq 1
    expect(limited.success_credit).to eq 0
  end

  it 'never decreases below min_cap' do
    view = initial(initial: 1, min: 1, ceiling: 4)

    expect(apply(view, 'rate_limit', initial: 1, min: 1, ceiling: 4).current_cap).to eq 1
    expect(apply(view, 'failure', initial: 1, min: 1, ceiling: 4).current_cap).to eq 1
  end

  it 'treats ordinary 4xx / 3xx / unknown as neutral' do
    view = initial
    credited = apply(view, 'success')

    expect(apply(credited, 'neutral').current_cap).to eq credited.current_cap
    expect(apply(credited, 'neutral').success_credit).to eq credited.success_credit
  end

  it 'does not change cap from latency alone' do
    view = initial
    credited = apply(view, 'success')

    expect(described_class.method(:apply).parameters.map(&:last)).not_to include(:request_duration_ms)
    expect(apply(credited, 'neutral').current_cap).to eq credited.current_cap
  end

  it 'resets stale state to initial before applying a new event' do
    now = Time.utc(2026, 9, 16, 12, 0, 0)
    payload = {
      'schema_version' => 1,
      'current_cap' => 4,
      'success_credit' => 1,
      'observed_at' => (now - 120).iso8601,
      'observed_at_unix' => (now - 120).to_i,
      'adaptive_profile_digest' => 'adapt-a',
      'fixed_profile_digest' => 'fixed-a',
    }

    view = described_class.view_from_payload(
      payload,
      params: params,
      now: now,
      stale_after: 60,
      adaptive_digest: 'adapt-a',
      fixed_digest: 'fixed-a',
      ceiling: 4
    )

    expect(view.current_cap).to eq 2
    expect(view.source).to eq 'stale_reset'
  end

  it 'resets to initial when the adaptive or fixed profile digest changes' do
    now = Time.utc(2026, 9, 16, 12, 0, 0)
    payload = {
      'schema_version' => 1,
      'current_cap' => 4,
      'success_credit' => 1,
      'observed_at' => now.iso8601,
      'observed_at_unix' => now.to_i,
      'adaptive_profile_digest' => 'adapt-old',
      'fixed_profile_digest' => 'fixed-a',
    }

    adaptive_changed = described_class.view_from_payload(
      payload,
      params: params,
      now: now,
      stale_after: 3600,
      adaptive_digest: 'adapt-a',
      fixed_digest: 'fixed-a',
      ceiling: 4
    )
    payload['adaptive_profile_digest'] = 'adapt-a'
    payload['fixed_profile_digest'] = 'fixed-old'
    fixed_changed = described_class.view_from_payload(
      payload,
      params: params,
      now: now,
      stale_after: 3600,
      adaptive_digest: 'adapt-a',
      fixed_digest: 'fixed-a',
      ceiling: 4
    )

    expect(adaptive_changed.current_cap).to eq 2
    expect(adaptive_changed.source).to eq 'digest_reset'
    expect(fixed_changed.current_cap).to eq 2
    expect(fixed_changed.source).to eq 'digest_reset'
  end

  it 'clamps a learned-high payload down to the current fixed ceiling' do
    now = Time.utc(2026, 9, 16, 12, 0, 0)
    view = described_class.view_from_payload(
      {
        'schema_version' => 1,
        'current_cap' => 99,
        'success_credit' => 0,
        'observed_at' => now.iso8601,
        'observed_at_unix' => now.to_i,
        'adaptive_profile_digest' => 'adapt-a',
        'fixed_profile_digest' => 'fixed-a',
      },
      params: params,
      now: now,
      stale_after: 3600,
      adaptive_digest: 'adapt-a',
      fixed_digest: 'fixed-a',
      ceiling: 4
    )

    expect(view.current_cap).to eq 4
    expect(view.source).to eq 'learned'
  end
end
