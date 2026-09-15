# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::DispatchPlan do
  it 'is a read-only summary that never selects work to claim' do
    plan = described_class.observe(
      observed_at: Time.utc(2026, 9, 15, 12, 0, 0),
      global_pending_count: 4,
      active_batch_count: 2,
      execution_config: { 'dispatch_shadow_enabled' => true }
    )

    expect(plan.global_pending_count).to eq 4
    expect(plan.active_batch_count).to eq 2
    expect(plan.claimed_count).to eq 0
    expect(plan).not_to respond_to(:selected_targets)
    expect(plan).not_to respond_to(:owner_key)
  end
end
