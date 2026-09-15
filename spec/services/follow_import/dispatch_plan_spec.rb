# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::DispatchPlan do
  it 'keeps claimed_count at 0 and leaves planned_count nil when planning was not attempted' do
    plan = described_class.observe(
      observed_at: Time.utc(2026, 9, 15, 12, 0, 0),
      global_pending_count: 4,
      active_batch_count: 2,
      execution_config: { 'dispatch_shadow_enabled' => true }
    )

    expect(plan.claimed_count).to eq 0
    expect(plan.planned_count).to be_nil
    expect(plan.planned_owner_count).to be_nil
    expect(plan.executable_owner_count).to be_nil
  end

  it 'exposes in-memory plan aggregates without claiming' do
    entries = [
      FollowImport::FairScheduler::Entry.new(owner_key: 'A', batch_id: 1, target_id: 10, position: 0, destination_domain: 'one.test'),
      FollowImport::FairScheduler::Entry.new(owner_key: 'A', batch_id: 2, target_id: 11, position: 0, destination_domain: 'two.test'),
      FollowImport::FairScheduler::Entry.new(owner_key: 'B', batch_id: 3, target_id: 12, position: 1, destination_domain: 'one.test'),
    ]
    plan = described_class.observe(
      observed_at: Time.now.utc,
      global_pending_count: 3,
      active_batch_count: 3,
      execution_config: {},
      planning: {
        planned: true,
        entries: entries,
        skipped_missing_owner_count: 1,
        shadow_plan_budget: 50,
        executable_owner_count: 100,
        executable_batch_count: 40,
      }
    )

    expect(plan.claimed_count).to eq 0
    expect(plan.planned_count).to eq 3
    expect(plan.planned_owner_count).to eq 2
    expect(plan.planned_batch_count).to eq 3
    expect(plan.executable_owner_count).to eq 100
    expect(plan.executable_batch_count).to eq 40
    expect(plan.unique_destination_count).to eq 2
    expect(plan.local_load_state).to be_nil
    expect(plan.effective_shadow_plan_budget).to be_nil
    expect(plan.skipped_missing_owner_count).to eq 1
    expect(plan.planned_counts_by_owner).to eq('A' => 2, 'B' => 1)
    expect(plan.planned_counts_by_destination).to eq('one.test' => 2, 'two.test' => 1)
  end
end
