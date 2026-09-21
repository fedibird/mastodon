# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::PreflightReleaseService do # rubocop:disable Metrics/BlockLength
  def create_batch(preflight_state:)
    FollowImportBatch.create!(
      subject: Fabricate(:moderation_subject),
      imported_at: Time.now.utc,
      mode: :merge,
      dispatch_owner: :legacy,
      dispatch_cohort: :operational,
      preflight_state: preflight_state,
      target_count: 0,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
  end

  it 'releases screening to ready exactly once' do
    batch = create_batch(preflight_state: :screening)

    result = described_class.new.call(batch)

    expect(result.batch_id).to eq batch.id
    expect(result.from).to eq 'screening'
    expect(result.to).to eq 'ready'
    expect(result.released?).to be true
    expect(result.transitioned).to be true
    expect(result).not_to respond_to(:score)
    expect(batch.reload.ready_preflight_state?).to be true
  end

  it 'is idempotent for an already-ready batch' do
    batch = create_batch(preflight_state: :ready)

    result = described_class.new.call(batch)

    expect(result.from).to eq 'ready'
    expect(result.to).to eq 'ready'
    expect(result.released?).to be true
    expect(result.transitioned).to be false
    expect(batch.reload.ready_preflight_state?).to be true
  end

  it 'does not release review_required' do
    batch = create_batch(preflight_state: :review_required)

    result = described_class.new.call(batch)

    expect(result.released?).to be false
    expect(result.transitioned).to be false
    expect(result.from).to eq 'review_required'
    expect(result.to).to eq 'review_required'
    expect(batch.reload.review_required_preflight_state?).to be true
  end

  it 'does not release stopped' do
    batch = create_batch(preflight_state: :stopped)

    result = described_class.new.call(batch)

    expect(result.released?).to be false
    expect(result.transitioned).to be false
    expect(result.from).to eq 'stopped'
    expect(result.to).to eq 'stopped'
    expect(batch.reload.stopped_preflight_state?).to be true
  end

  it 'does not enqueue relationship work' do
    allow(Import::RelationshipWorker).to receive(:perform_async)
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
    batch = create_batch(preflight_state: :screening)

    described_class.new.call(batch)

    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
  end
end
