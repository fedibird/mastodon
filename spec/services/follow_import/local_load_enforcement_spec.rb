# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::LocalLoadEnforcement do
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

  def v2_profile(overrides = {})
    {
      'version' => 2,
      'levels' => {
        'busy' => { 'budget_percent' => 40, 'push' => { 'latency' => 2 } },
        'overloaded' => { 'budget_percent' => 0, 'push' => { 'latency' => 20 } },
      },
      'fallback' => { 'budget_percent' => 20 },
    }.merge(overrides)
  end

  def evaluate(load_snapshot: snapshot, base_budget: 10)
    described_class.evaluate(load_snapshot: load_snapshot, base_budget: base_budget)
  end

  it 'returns the legacy base budget without evaluating the guard when the flag is off' do
    allow(FollowImport::LocalLoadGuard).to receive(:evaluate)
    allow(FollowImport::LocalLoadProfile).to receive(:from_env)

    result = evaluate

    expect(result.enabled).to be false
    expect(result.effective_budget).to eq 10
    expect(result.fallback_used).to be_nil
    expect(result.skip_selection?).to be false
    expect(FollowImport::LocalLoadGuard).not_to have_received(:evaluate)
    expect(FollowImport::LocalLoadProfile).not_to have_received(:from_env)
  end

  context 'when enforcement is enabled' do
    before { allow(FollowImport::ExecutionPolicy).to receive(:local_load_enforcement_enabled?).and_return(true) }

    it 'keeps the legacy budget and warns when no enforcement-capable profile is set' do
      allow(FollowImport::Telemetry).to receive(:warn_failure)
      allow(FollowImport::LocalLoadProfile).to receive(:from_env).and_return(profile(nil))

      result = evaluate

      expect(result.enabled).to be true
      expect(result.configured).to be false
      expect(result.effective_budget).to eq 10
      expect(result.decision.state).to eq 'unconfigured'
      expect(result.decision.state).not_to eq 'normal'
      expect(result.skip_selection?).to be false
      expect(FollowImport::Telemetry).to have_received(:warn_failure)
        .with('local_load_enforcement', instance_of(described_class::NotConfigured))
    end

    it 'does not treat a valid v1 shadow profile as enforceable' do
      allow(FollowImport::Telemetry).to receive(:warn_failure)
      allow(FollowImport::LocalLoadProfile).to receive(:from_env).and_return(
        profile('version' => 1, 'levels' => { 'overloaded' => { 'budget_percent' => 0, 'push' => { 'latency' => 0 } } })
      )

      result = evaluate

      expect(result.configured).to be false
      expect(result.effective_budget).to eq 10
      expect(result.decision.state).to eq 'unconfigured'
      expect(result.decision.reasons).to include('enforcement_profile_required')
    end

    it 'uses a healthy recommendation without shrinking below the observed value' do
      allow(FollowImport::LocalLoadProfile).to receive(:from_env).and_return(profile(v2_profile))

      result = evaluate(base_budget: 10)

      expect(result.configured).to be true
      expect(result.effective_budget).to eq 10
      expect(result.decision.state).to eq 'normal'
      expect(result.fallback_used).to be false
      expect(result.skip_selection?).to be false
    end

    it 'shrinks to the recommendation and never above the base budget' do
      allow(FollowImport::LocalLoadProfile).to receive(:from_env).and_return(profile(v2_profile))

      result = evaluate(
        load_snapshot: snapshot('queues' => { 'push' => { 'size' => 0, 'latency' => 3.0 } }),
        base_budget: 10
      )

      expect(result.effective_budget).to eq 4
      expect(result.decision.recommended_budget).to eq 4
      expect(result.fallback_used).to be false
    end

    it 'defers selection when the recommendation is 0' do
      allow(FollowImport::LocalLoadProfile).to receive(:from_env).and_return(profile(v2_profile))

      result = evaluate(
        load_snapshot: snapshot('queues' => { 'push' => { 'size' => 0, 'latency' => 25.0 } }),
        base_budget: 10
      )

      expect(result.effective_budget).to eq 0
      expect(result.skip_selection?).to be true
      expect(result.fallback_used).to be false
    end

    it 'applies the explicit fallback when a required measurement is missing' do
      allow(FollowImport::LocalLoadProfile).to receive(:from_env).and_return(profile(v2_profile))

      result = evaluate(
        load_snapshot: snapshot('queues' => { 'push' => { 'error_class' => 'RuntimeError' } }),
        base_budget: 10
      )

      expect(result.decision.state).to eq 'unknown'
      expect(result.decision.recommended_budget).to be_nil
      expect(result.effective_budget).to eq 2
      expect(result.fallback_used).to be true
      expect(result.skip_selection?).to be false
    end

    it 'applies the explicit fallback when the controller raises' do
      allow(FollowImport::Telemetry).to receive(:warn_failure)
      allow(FollowImport::LocalLoadProfile).to receive(:from_env).and_return(profile(v2_profile))
      allow_any_instance_of(FollowImport::LocalLoadGuard).to receive(:missing_measurements)
        .and_raise(RuntimeError, 'internal boom')

      result = evaluate(base_budget: 10)

      expect(result.decision.state).to eq 'evaluation_error'
      expect(result.effective_budget).to eq 2
      expect(result.fallback_used).to be true
      expect(FollowImport::Telemetry).to have_received(:warn_failure).with('local_load_guard', instance_of(RuntimeError))
    end

    it 'may apply a configured fallback of 0' do
      allow(FollowImport::LocalLoadProfile).to receive(:from_env).and_return(
        profile(v2_profile.merge('fallback' => { 'budget_percent' => 0 }))
      )

      result = evaluate(
        load_snapshot: snapshot('queues' => { 'push' => { 'error_class' => 'RuntimeError' } }),
        base_budget: 10
      )

      expect(result.effective_budget).to eq 0
      expect(result.fallback_used).to be true
      expect(result.skip_selection?).to be true
    end
  end
end
