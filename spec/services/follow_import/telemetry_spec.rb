# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::Telemetry do
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

  it 'forces claimed_count to 0 on tick observations even if a caller passes a positive value' do
    row = described_class.record_dispatch_tick(
      tick_id: 'tick-zero',
      outcome: 'shadow_observed',
      lease_acquired: true,
      claimed_count: 12,
      global_pending_count: 3,
      active_batch_count: 1
    )

    expect(row.claimed_count).to eq 0
    expect(row.global_pending_count).to eq 3
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
    expect(row.executable_owner_count).to be_nil
    expect(row.skipped_missing_owner_count).to be_nil
    expect(row.claimed_count).to eq 0
  end
end

