# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::Telemetry do # rubocop:disable Metrics/BlockLength
  it 'swallows transport insert failures and logs a warning' do
    allow(FollowImportTransportObservation).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')
    allow(Rails.logger).to receive(:warn)

    expect(
      described_class.record_transport(
        phase: 'resolve_account',
        outcome: 'resolved',
        started_at: Time.now.utc,
        finished_at: Time.now.utc
      )
    ).to be_nil

    expect(Rails.logger).to have_received(:warn).with(/FollowImport::Telemetry.*transport/)
  end

  it 'swallows dispatch insert failures and logs a warning' do
    allow(FollowImportDispatchObservation).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')
    allow(Rails.logger).to receive(:warn)

    expect(described_class.record_dispatch(candidate_count: 1, claimed_count: 1, pending_count: nil)).to be_nil
    expect(Rails.logger).to have_received(:warn).with(/FollowImport::Telemetry.*dispatch/)
  end

  it 'persists nil backlog counts instead of coercing them to zero' do
    row = described_class.record_dispatch(
      candidate_count: 0,
      claimed_count: 0,
      pending_count: nil,
      batch_pending_before: nil,
      batch_pending_after: nil,
      global_pending_count: nil,
      active_batch_count: nil,
      load_snapshot: nil
    )

    expect(row.pending_count).to be_nil
    expect(row.batch_pending_before).to be_nil
    expect(row.global_pending_count).to be_nil
    expect(row.active_batch_count).to be_nil
    expect(row.load_snapshot).to be_nil
    expect(row.local_load_state).to be_nil
    expect(row.effective_execution_budget).to be_nil
    expect(row.load_deferred).to be_nil
    expect(row.local_load_decision).to be_nil
  end

  it 'swallows dispatch-tick insert failures and logs a warning' do
    allow(FollowImportDispatchTickObservation).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')
    allow(Rails.logger).to receive(:warn)

    expect(
      described_class.record_dispatch_tick(
        tick_id: 'tick',
        outcome: 'shadow_observed',
        lease_acquired: true,
        claimed_count: 99
      )
    ).to be_nil

    expect(Rails.logger).to have_received(:warn).with(/FollowImport::Telemetry.*dispatch_tick/)
  end

  it 'forces claimed_count to 0 on shadow tick observations even if a caller passes a positive value' do
    row = described_class.record_dispatch_tick(
      tick_id: 'tick-zero',
      outcome: 'shadow_observed',
      scheduler_mode: 'shadow',
      lease_acquired: true,
      claimed_count: 12,
      global_pending_count: 3,
      active_batch_count: 1
    )

    expect(row.scheduler_mode).to eq 'shadow'
    expect(row.claimed_count).to eq 0
    expect(row.global_pending_count).to eq 3
  end

  it 'defaults a missing scheduler_mode to shadow and still forces claimed_count 0' do
    row = described_class.record_dispatch_tick(
      tick_id: 'tick-default-shadow',
      outcome: 'shadow_observed',
      lease_acquired: true,
      claimed_count: 4
    )

    expect(row.scheduler_mode).to eq 'shadow'
    expect(row.claimed_count).to eq 0
  end

  it 'persists the actual claimed_count for a global authoritative tick' do
    row = described_class.record_dispatch_tick(
      tick_id: 'tick-global',
      outcome: 'global_observed',
      scheduler_mode: 'global',
      lease_acquired: true,
      claimed_count: 3,
      planned_count: 10,
      global_base_budget: 10,
      effective_global_budget: 10,
      skipped_stale_count: 0,
      error_class: 'RuntimeError'
    )

    expect(row.scheduler_mode).to eq 'global'
    expect(row.claimed_count).to eq 3
    expect(row.planned_count).to eq 10
    expect(row.global_base_budget).to eq 10
    expect(row.effective_global_budget).to eq 10
    expect(row.error_class).to eq 'RuntimeError'
  end

  it 'persists nil tick backlog counts instead of coercing them to zero' do
    row = described_class.record_dispatch_tick(
      tick_id: 'tick-nil',
      outcome: 'shadow_observed',
      lease_acquired: true,
      global_pending_count: nil,
      active_batch_count: nil,
      load_snapshot: nil
    )

    expect(row.global_pending_count).to be_nil
    expect(row.active_batch_count).to be_nil
    expect(row.load_snapshot).to be_nil
    expect(row.claimed_count).to eq 0
  end

  it 'persists scoped tick backlog 0 without coercing sibling NULLs' do
    row = described_class.record_dispatch_tick(
      tick_id: 'tick-scoped',
      outcome: 'shadow_observed',
      scheduler_mode: 'shadow',
      lease_acquired: true,
      global_pending_count: 4,
      active_batch_count: 2,
      historical_pending_count: 4,
      operational_pending_count: 0,
      planning_pending_count: 0,
      historical_active_batch_count: 2,
      operational_active_batch_count: 0,
      planning_active_batch_count: 0,
      execution_config: {
        'schema_version' => FollowImport::DispatchTickObserver::SCHEMA_VERSION,
        'backlog_scope_strategy' => FollowImport::DispatchTickObserver::BACKLOG_SCOPE_STRATEGY,
      }
    )

    expect(row.global_pending_count).to eq 4
    expect(row.historical_pending_count).to eq 4
    expect(row.operational_pending_count).to eq 0
    expect(row.planning_pending_count).to eq 0
    expect(row.historical_active_batch_count).to eq 2
    expect(row.operational_active_batch_count).to eq 0
    expect(row.planning_active_batch_count).to eq 0
    expect(row.execution_config['schema_version']).to eq 10
    expect(row.execution_config['backlog_scope_strategy']).to eq 'dispatch_cohort_v1'
  end

  it 'persists NULL scoped tick backlog counts instead of coercing them to zero' do
    row = described_class.record_dispatch_tick(
      tick_id: 'tick-scoped-nil',
      outcome: 'global_observed',
      scheduler_mode: 'global',
      lease_acquired: true,
      global_pending_count: nil,
      active_batch_count: nil,
      historical_pending_count: nil,
      operational_pending_count: nil,
      planning_pending_count: nil,
      historical_active_batch_count: nil,
      operational_active_batch_count: nil,
      planning_active_batch_count: nil
    )

    expect(row.historical_pending_count).to be_nil
    expect(row.operational_pending_count).to be_nil
    expect(row.planning_pending_count).to be_nil
    expect(row.historical_active_batch_count).to be_nil
    expect(row.operational_active_batch_count).to be_nil
    expect(row.planning_active_batch_count).to be_nil
    expect(row.claimed_count).to eq 0
  end

  it 'persists nil plan aggregates instead of coercing them to zero' do
    row = described_class.record_dispatch_tick(
      tick_id: 'tick-plan-nil',
      outcome: 'lease_busy',
      lease_acquired: false,
      planned_count: nil,
      planned_owner_count: nil,
      executable_owner_count: nil,
      skipped_missing_owner_count: nil
    )

    expect(row.planned_count).to be_nil
    expect(row.planned_owner_count).to be_nil
    expect(row.local_load_state).to be_nil
    expect(row.local_load_recommended_budget).to be_nil
    expect(row.executable_owner_count).to be_nil
    expect(row.skipped_missing_owner_count).to be_nil
    expect(row.claimed_count).to eq 0
  end
end
