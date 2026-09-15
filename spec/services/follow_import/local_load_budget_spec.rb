# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::LocalLoadBudget do
  def profile(payload)
    FollowImport::LocalLoadProfile.parse(payload)
  end

  def snapshot(attrs = {})
    {
      'queues' => {
        'default' => { 'size' => 0, 'latency' => 0.0 },
        'push' => { 'size' => 0, 'latency' => 0.1 },
        'pull' => { 'size' => 0, 'latency' => 0.0 },
      },
      'retry_size' => 0,
      'push_concurrency' => 4,
      'pull_concurrency' => 2,
    }.merge(attrs)
  end

  def v2_profile
    {
      'version' => 2,
      'levels' => {
        'busy' => { 'budget_percent' => 40, 'push' => { 'latency' => 2 } },
        'overloaded' => { 'budget_percent' => 0, 'push' => { 'latency' => 20 } },
      },
      'fallback' => { 'budget_percent' => 20 },
    }
  end

  def unknown_snapshot
    snapshot('queues' => { 'push' => { 'error_class' => 'RuntimeError' } })
  end

  it 'applies the same v2 fallback percent to shadow and legacy bases' do
    injected = profile(v2_profile)

    shadow = described_class.resolve(snapshot: unknown_snapshot, base_budget: 50, profile: injected)
    legacy = described_class.resolve(snapshot: unknown_snapshot, base_budget: 10, profile: injected)

    expect(shadow.decision.state).to eq 'unknown'
    expect(legacy.decision.state).to eq 'unknown'
    expect(shadow.effective_budget).to eq 10
    expect(legacy.effective_budget).to eq 2
    expect(shadow.fallback_used).to be true
    expect(legacy.fallback_used).to be true
  end

  it 'keeps the v1 unknown path at the supplied base because v1 has no fallback' do
    injected = profile(
      'version' => 1,
      'levels' => { 'busy' => { 'budget_percent' => 50, 'push' => { 'latency' => 1 } } }
    )

    result = described_class.resolve(snapshot: unknown_snapshot, base_budget: 50, profile: injected)

    expect(result.decision.state).to eq 'unknown'
    expect(result.effective_budget).to eq 50
    expect(result.fallback_used).to be false
  end

  it 'uses evaluation_error plus the v2 fallback when LocalLoadGuard.evaluate raises' do
    allow(FollowImport::Telemetry).to receive(:warn_failure)
    allow(FollowImport::LocalLoadGuard).to receive(:evaluate).and_raise(RuntimeError, 'boom')
    injected = profile(v2_profile)

    result = described_class.resolve(snapshot: snapshot, base_budget: 50, profile: injected)

    expect(result.decision.state).to eq 'evaluation_error'
    expect(result.decision.invalid?).to be false
    expect(result.effective_budget).to eq 10
    expect(result.fallback_used).to be true
    expect(FollowImport::Telemetry).to have_received(:warn_failure).with('local_load_budget', instance_of(RuntimeError))
  end
end
