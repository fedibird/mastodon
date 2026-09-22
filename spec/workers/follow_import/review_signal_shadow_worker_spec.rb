# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::ReviewSignalShadowWorker do
  subject(:worker) { described_class.new }

  def create_batch(cohort: :operational, **attrs)
    FollowImportBatch.create!(
      {
        subject: ModerationSubject.for_account!(Fabricate(:account)),
        imported_at: Time.utc(2026, 9, 21, 12, 0, 0),
        mode: :merge,
        dispatch_owner: :legacy,
        dispatch_cohort: cohort,
        preflight_state: :ready,
        target_count: 1,
        resolved_target_count: 1,
        unresolved_target_count: 0,
      }.merge(attrs)
    )
  end

  it 'evaluates and stores the first observation for an operational batch' do
    batch = create_batch
    payload = { 'schema_version' => 1, 'signal_level' => 'low', 'marker' => 'stored-shadow' }
    allow_any_instance_of(FollowImport::ReviewSignalShadowEvaluator).to receive(:call).and_return(payload)

    worker.perform(batch.id)

    fresh = FollowImportBatch.find(batch.id)
    expect(fresh.review_signal_shadow_v1).to eq payload
    expect(fresh.ready_preflight_state?).to be true
    expect(fresh.legacy_dispatch_owner?).to be true
  end

  it 'does not replace an observation that is already stored' do
    batch = create_batch
    batch.record_review_signal_shadow_v1!('marker' => 'kept')
    expect(FollowImport::ReviewSignalShadowEvaluator).not_to receive(:new)

    worker.perform(batch.id)

    expect(batch.reload.review_signal_shadow_v1['marker']).to eq 'kept'
  end

  it 'does nothing for a historical cohort batch' do
    batch = create_batch(cohort: :historical)
    expect(FollowImport::ReviewSignalShadowEvaluator).not_to receive(:new)

    worker.perform(batch.id)

    expect(batch.reload.review_signal_shadow_v1_recorded?).to be false
    expect(batch.historical_dispatch_cohort?).to be true
  end

  it 'does nothing when the batch is missing' do
    expect(FollowImport::ReviewSignalShadowEvaluator).not_to receive(:new)

    expect { worker.perform(-1) }.not_to raise_error
  end

  it 'retries a transient evaluator failure without writing a fake observation or changing execution' do
    batch = create_batch
    allow_any_instance_of(FollowImport::ReviewSignalShadowEvaluator).to receive(:call).and_raise(Timeout::Error, 'db down with secret@example.com')

    expect { worker.perform(batch.id) }.to raise_error(Timeout::Error)
    fresh = batch.reload
    expect(fresh.review_signal_shadow_v1_recorded?).to be false
    expect(fresh.ready_preflight_state?).to be true
    expect(fresh.metadata.to_json).not_to include('secret@example.com')
    expect(fresh.metadata.to_json).not_to include('db down')
  end
end
