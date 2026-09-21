# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImportBatch do # rubocop:disable Metrics/BlockLength
  let(:subject_record) { Fabricate(:moderation_subject) }

  def create_batch(**attrs)
    described_class.create!(
      {
        subject: subject_record,
        imported_at: Time.now.utc,
        mode: :merge,
        target_count: 0,
        resolved_target_count: 0,
        unresolved_target_count: 0,
      }.merge(attrs)
    )
  end

  it 'defaults new rows to legacy dispatch ownership' do
    batch = create_batch

    expect(batch.dispatch_owner).to eq 'legacy'
    expect(batch.legacy_dispatch_owner?).to be true
    expect(batch.scheduler_dispatch_owner?).to be false
  end

  it 'defaults new rows to the fail-safe historical dispatch cohort' do
    batch = create_batch

    expect(batch.dispatch_cohort).to eq 'historical'
    expect(batch.historical_dispatch_cohort?).to be true
    expect(batch.operational_dispatch_cohort?).to be false
    expect(described_class.historical_cohort).to include(batch)
    expect(described_class.operational_cohort).not_to include(batch)
    expect(described_class.shadow_planning_scope).not_to include(batch)
    expect(described_class.global_planning_scope).not_to include(batch)
  end

  it 'accepts scheduler ownership when the application selects it' do
    batch = create_batch(dispatch_owner: :scheduler)

    expect(batch.scheduler_dispatch_owner?).to be true
    expect(batch.legacy_dispatch_owner?).to be false
    expect(described_class.scheduler_owned).to include(batch)
    expect(described_class.legacy_owned).not_to include(batch)
  end

  it 'accepts operational cohort when the application selects it' do
    batch = create_batch(dispatch_cohort: :operational)

    expect(batch.operational_dispatch_cohort?).to be true
    expect(described_class.operational_cohort).to include(batch)
    expect(described_class.shadow_planning_scope).to include(batch)
    expect(described_class.global_planning_scope).not_to include(batch)
  end

  it 'includes only operational scheduler-owned rows in the GLOBAL planning scope' do
    historical_scheduler = create_batch(dispatch_owner: :scheduler, dispatch_cohort: :historical)
    operational_legacy = create_batch(dispatch_owner: :legacy, dispatch_cohort: :operational)
    operational_scheduler = create_batch(dispatch_owner: :scheduler, dispatch_cohort: :operational)

    expect(described_class.global_planning_scope).to contain_exactly(operational_scheduler)
    expect(described_class.shadow_planning_scope).to contain_exactly(operational_legacy, operational_scheduler)
    expect(described_class.shadow_planning_scope).not_to include(historical_scheduler)
  end

  it 'rejects an unsupported dispatch_owner' do
    expect { create_batch(dispatch_owner: :remote) }.to raise_error(ArgumentError)
  end

  it 'rejects an unsupported dispatch_cohort' do
    expect { create_batch(dispatch_cohort: :staging) }.to raise_error(ArgumentError)
  end
end
