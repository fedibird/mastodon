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

  it 'defaults new rows to ready preflight so existing inserts stay executable' do
    batch = create_batch

    expect(batch.preflight_state).to eq 'ready'
    expect(batch.ready_preflight_state?).to be true
    expect(batch.screening_preflight_state?).to be false
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
    expect(operational_scheduler.globally_claimable?).to be true
    expect(historical_scheduler.globally_claimable?).to be false
    expect(operational_legacy.globally_claimable?).to be false
    expect(described_class.shadow_planning_scope).to contain_exactly(operational_legacy, operational_scheduler)
    expect(described_class.shadow_planning_scope).not_to include(historical_scheduler)
  end

  it 'excludes non-ready operational rows from planning scopes and GLOBAL claims' do
    screening = create_batch(dispatch_owner: :scheduler, dispatch_cohort: :operational, preflight_state: :screening)
    review_required = create_batch(dispatch_owner: :scheduler, dispatch_cohort: :operational, preflight_state: :review_required)
    stopped = create_batch(dispatch_owner: :scheduler, dispatch_cohort: :operational, preflight_state: :stopped)
    ready = create_batch(dispatch_owner: :scheduler, dispatch_cohort: :operational, preflight_state: :ready)
    ready_legacy = create_batch(dispatch_owner: :legacy, dispatch_cohort: :operational, preflight_state: :ready)

    expect(described_class.global_planning_scope).to contain_exactly(ready)
    expect(described_class.shadow_planning_scope).to contain_exactly(ready, ready_legacy)
    expect(described_class.operational_cohort).to include(screening, review_required, stopped, ready, ready_legacy)
    expect(ready.globally_claimable?).to be true
    expect(screening.globally_claimable?).to be false
    expect(review_required.globally_claimable?).to be false
    expect(stopped.globally_claimable?).to be false
    expect(ready_legacy.globally_claimable?).to be false
  end

  it 'rejects an unsupported dispatch_owner' do
    expect { create_batch(dispatch_owner: :remote) }.to raise_error(ArgumentError)
  end

  it 'rejects an unsupported dispatch_cohort' do
    expect { create_batch(dispatch_cohort: :staging) }.to raise_error(ArgumentError)
  end

  it 'rejects an unsupported preflight_state' do
    expect { create_batch(preflight_state: :safe) }.to raise_error(ArgumentError)
  end

  describe 'metadata merges' do
    let(:at) { Time.utc(2026, 9, 21, 3, 0, 0) }

    def fresh_copies
      batch = create_batch(preflight_state: :review_required, dispatch_cohort: :operational)
      [batch, described_class.find(batch.id), described_class.find(batch.id)]
    end

    it 'keeps completed_at when a stale instance records resume completion' do
      _batch, completion_writer, resume_writer = fresh_copies

      completion_writer.record_completion!(at)
      resume_writer.mark_review_resume_completed!(at + 60)

      fresh = described_class.find(completion_writer.id)
      expect(fresh.metadata[described_class::COMPLETED_AT_KEY]).to eq at.iso8601
      expect(fresh.metadata[described_class::REVIEW_RESUME_COMPLETED_AT_KEY]).to eq (at + 60).iso8601
    end

    it 'keeps resume completion when a stale instance records completion' do
      _batch, completion_writer, resume_writer = fresh_copies

      resume_writer.mark_review_resume_completed!(at)
      completion_writer.record_completion!(at + 60)

      fresh = described_class.find(completion_writer.id)
      expect(fresh.metadata[described_class::REVIEW_RESUME_COMPLETED_AT_KEY]).to eq at.iso8601
      expect(fresh.metadata[described_class::COMPLETED_AT_KEY]).to eq (at + 60).iso8601
    end

    it 'keeps resume completion when a stale instance records the notification stamp' do
      _batch, notified_writer, resume_writer = fresh_copies

      resume_writer.mark_review_resume_completed!(at)
      notified_writer.mark_completion_notified!(at + 60)

      fresh = described_class.find(resume_writer.id)
      expect(fresh.metadata[described_class::REVIEW_RESUME_COMPLETED_AT_KEY]).to eq at.iso8601
      expect(fresh.metadata[described_class::COMPLETION_NOTIFIED_KEY]).to eq (at + 60).iso8601
    end

    it 'keeps completed_at when a stale instance marks resume required and ready' do
      _batch, completion_writer, resume_writer = fresh_copies

      completion_writer.record_completion!(at)
      resume_writer.mark_review_resume_required!(at + 60)

      fresh = described_class.find(resume_writer.id)
      expect(fresh.ready_preflight_state?).to be true
      expect(fresh.metadata[described_class::COMPLETED_AT_KEY]).to eq at.iso8601
      expect(fresh.metadata[described_class::REVIEW_RESUME_REQUIRED_AT_KEY]).to eq (at + 60).iso8601
    end

    it 'keeps resume completion when a stale settled batch records completion' do
      batch, = fresh_copies
      batch.targets.create!(target_key_hash: 'settled', position: 0, state: :accepted)
      stale = described_class.find(batch.id)
      batch.mark_review_resume_completed!(at)

      stale.record_completion_if_settled!(at + 30)

      fresh = described_class.find(batch.id)
      expect(fresh.metadata[described_class::REVIEW_RESUME_COMPLETED_AT_KEY]).to eq at.iso8601
      expect(fresh.metadata[described_class::COMPLETED_AT_KEY]).to eq (at + 30).iso8601
    end
  end
end
