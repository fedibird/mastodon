# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduler::FollowImportReviewSignalShadowScheduler do
  subject(:worker) { described_class.new }

  def create_batch(cohort: :operational, imported_at: 1.hour.ago, shadow: false)
    batch = FollowImportBatch.create!(
      subject: ModerationSubject.for_account!(Fabricate(:account)),
      imported_at: imported_at,
      mode: :merge,
      dispatch_owner: :legacy,
      dispatch_cohort: cohort,
      preflight_state: :ready,
      target_count: 0,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
    batch.record_review_signal_shadow_v1!('marker' => 'already') if shadow
    batch
  end

  before do
    allow(FollowImport::ReviewSignalShadowWorker).to receive(:perform_async)
  end

  it 'enqueues recent operational batches that have no v1 observation' do
    recent = create_batch
    recorded = create_batch(shadow: true)
    historical = create_batch(cohort: :historical)
    stale = create_batch(imported_at: 8.days.ago)

    worker.perform

    expect(FollowImport::ReviewSignalShadowWorker).to have_received(:perform_async).with(recent.id)
    expect(FollowImport::ReviewSignalShadowWorker).not_to have_received(:perform_async).with(recorded.id)
    expect(FollowImport::ReviewSignalShadowWorker).not_to have_received(:perform_async).with(historical.id)
    expect(FollowImport::ReviewSignalShadowWorker).not_to have_received(:perform_async).with(stale.id)
    expect(recent.reload.preflight_state).to eq 'ready'
    expect(stale.reload.historical_dispatch_cohort?).to be false
  end

  it 'bounds each pass' do
    relation = FollowImportBatch.none
    allow(worker).to receive(:candidates).and_return(relation)
    expect(relation).to receive(:limit).with(described_class::BATCH_LIMIT).and_return(relation)

    worker.perform
  end
end
