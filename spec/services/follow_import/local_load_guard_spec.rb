# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::LocalLoadGuard do
  def profile_for(payload)
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

  def evaluate(snapshot:, base_budget:, profile:)
    described_class.evaluate(snapshot: snapshot, base_budget: base_budget, profile: profile)
  end

  let(:graded_profile) do
    profile_for(
      'version' => 1,
      'levels' => {
        'busy' => { 'budget_percent' => 50, 'push' => { 'latency' => 2 } },
        'heavy' => { 'budget_percent' => 10, 'retry_size' => 50 },
        'overloaded' => { 'budget_percent' => 0, 'push' => { 'latency' => 20 } },
      }
    )
  end

  it 'returns normal and 100% when no configured threshold is crossed' do
    decision = evaluate(snapshot: snapshot, base_budget: 50, profile: graded_profile)

    expect(decision.state).to eq 'normal'
    expect(decision.budget_percent).to eq 100
    expect(decision.recommended_budget).to eq 50
    expect(decision.would_skip).to be false
    expect(decision.measurement_complete).to be true
  end

  it 'applies the busy percentage when one busy threshold is crossed' do
    decision = evaluate(
      snapshot: snapshot('queues' => { 'push' => { 'size' => 0, 'latency' => 3.0 } }),
      base_budget: 10,
      profile: graded_profile
    )

    expect(decision.state).to eq 'busy'
    expect(decision.budget_percent).to eq 50
    expect(decision.recommended_budget).to eq 5
    expect(decision.reasons).to include('push_latency')
    expect(decision.would_skip).to be false
  end

  it 'uses the strongest crossed level and keeps all applicable reasons' do
    decision = evaluate(
      snapshot: snapshot(
        'queues' => { 'push' => { 'size' => 0, 'latency' => 3.0 } },
        'retry_size' => 80
      ),
      base_budget: 10,
      profile: graded_profile
    )

    expect(decision.state).to eq 'heavy'
    expect(decision.budget_percent).to eq 10
    expect(decision.recommended_budget).to eq 1
    expect(decision.reasons).to include('push_latency', 'retry_size')
  end

  it 'computes a hard shadow skip when overloaded is configured at 0%' do
    decision = evaluate(
      snapshot: snapshot('queues' => { 'push' => { 'size' => 0, 'latency' => 25.0 } }),
      base_budget: 10,
      profile: graded_profile
    )

    expect(decision.state).to eq 'overloaded'
    expect(decision.budget_percent).to eq 0
    expect(decision.recommended_budget).to eq 0
    expect(decision.would_skip).to be true
  end

  it 'clamps through configured capacity without inventing constants' do
    profile = profile_for(
      'version' => 1,
      'capacity' => { 'per_push_thread' => 3, 'max_tick_claims' => 40 }
    )
    decision = evaluate(snapshot: snapshot('push_concurrency' => 4), base_budget: 50, profile: profile)

    expect(decision.state).to eq 'normal'
    expect(decision.recommended_budget).to eq 12
    expect(decision.reasons).to include('push_capacity')
  end

  it 'returns unknown with a nil recommendation when a required metric is missing' do
    decision = evaluate(
      snapshot: snapshot('queues' => { 'push' => { 'error_class' => 'RuntimeError' } }),
      base_budget: 10,
      profile: graded_profile
    )

    expect(decision.state).to eq 'unknown'
    expect(decision.measurement_complete).to be false
    expect(decision.recommended_budget).to be_nil
    expect(decision.budget_percent).to be_nil
    expect(decision.would_skip).to be_nil
    expect(decision.reasons).to include('push_latency')
  end

  it 'stays complete when an unused metric is missing' do
    profile = profile_for(
      'version' => 1,
      'levels' => { 'busy' => { 'budget_percent' => 50, 'push' => { 'size' => 10 } } }
    )
    decision = evaluate(
      snapshot: {
        'queues' => { 'push' => { 'size' => 1 } },
        'retry_size_error_class' => 'RuntimeError',
      },
      base_budget: 8,
      profile: profile
    )

    expect(decision.state).to eq 'normal'
    expect(decision.measurement_complete).to be true
    expect(decision.recommended_budget).to eq 8
  end

  it 'does not raise on an invalid profile and does not reduce the budget' do
    decision = evaluate(snapshot: snapshot, base_budget: 10, profile: profile_for('{nope'))

    expect(decision.state).to eq 'invalid'
    expect(decision.recommended_budget).to be_nil
    expect(decision.apply_to_shadow_plan?).to be false
  end

  it 'treats a blank profile as unconfigured' do
    decision = evaluate(snapshot: snapshot, base_budget: 10, profile: profile_for(nil))

    expect(decision.state).to eq 'unconfigured'
    expect(decision.recommended_budget).to be_nil
    expect(decision.apply_to_shadow_plan?).to be false
  end

  it 'is deterministic for the same profile, snapshot, and base budget' do
    first = evaluate(snapshot: snapshot, base_budget: 10, profile: graded_profile)
    second = evaluate(snapshot: snapshot, base_budget: 10, profile: graded_profile)

    expect(first.state).to eq second.state
    expect(first.recommended_budget).to eq second.recommended_budget
    expect(first.reasons).to eq second.reasons
  end

  it 'does not query Sidekiq or telemetry tables' do
    allow(Sidekiq::Queue).to receive(:new)
    allow(Sidekiq::Stats).to receive(:new)
    allow(FollowImportDispatchTickObservation).to receive(:where)

    evaluate(snapshot: snapshot, base_budget: 10, profile: graded_profile)

    expect(Sidekiq::Queue).not_to have_received(:new)
    expect(Sidekiq::Stats).not_to have_received(:new)
    expect(FollowImportDispatchTickObservation).not_to have_received(:where)
  end
end
