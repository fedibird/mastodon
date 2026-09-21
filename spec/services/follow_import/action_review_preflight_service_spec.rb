# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::ActionReviewPreflightService do # rubocop:disable Metrics/BlockLength
  def evidence_keys
    %w(
      schema_version batch_id imported_at mode target_count resolved_target_count
      unresolved_target_count account_age_seconds migration_evidence dispatch_owner
    )
  end

  def create_batch(preflight_state: :screening, **attrs)
    FollowImportBatch.create!(
      {
        subject: ModerationSubject.for_account!(Fabricate(:account)),
        imported_at: Time.utc(2026, 9, 21, 12, 0, 0),
        mode: :merge,
        dispatch_owner: :legacy,
        dispatch_cohort: :operational,
        preflight_state: preflight_state,
        target_count: 2,
        resolved_target_count: 2,
        unresolved_target_count: 0,
        account_age_seconds: 756,
        migration_evidence: :none,
      }.merge(attrs)
    )
  end

  def stub_policies(value)
    allow(Setting).to receive(:[]).and_wrap_original do |method, key|
      key.to_s == 'action_review_policies' ? value : method.call(key)
    end
  end

  def release(batch)
    described_class.new.call(batch)
  end

  %w(off high medium low).each do |mode|
    it "releases screening to ready for #{mode} when the signal is none and creates no request" do
      stub_policies('follow_import' => mode)
      batch = create_batch
      batch.targets.create!(target_key_hash: 'raw-address-hash-secret', position: 0)

      result = release(batch)

      expect(result.released?).to be true
      expect(result.from).to eq 'screening'
      expect(result.to).to eq 'ready'
      expect(batch.reload.ready_preflight_state?).to be true
      expect(ActionReviewRequest.count).to eq 0
    end
  end

  it 'holds screening as review_required and stores minimized evidence when policy is always' do
    stub_policies('follow_import' => 'always')
    batch = create_batch
    batch.targets.create!(target_key_hash: 'raw-address-hash-secret', position: 0)

    result = release(batch)
    request = ActionReviewRequest.last

    expect(result.released?).to be false
    expect(result.to).to eq 'review_required'
    expect(batch.reload.review_required_preflight_state?).to be true
    expect(request.operation_type).to eq 'follow_import'
    expect(request.pending_state?).to be true
    expect(request.actor_account).to eq batch.for_account
    expect(request.resource).to eq batch
    expect(request.evaluator_version).to be_nil
    expect(request.signal_level).to eq 'none'
    expect(request.evidence.keys).to match_array(evidence_keys)
    expect(request.evidence['schema_version']).to eq 1
    expect(request.evidence['batch_id']).to eq batch.id
    expect(request.evidence['mode']).to eq 'merge'
    expect(request.evidence['target_count']).to eq 2
    expect(request.evidence['dispatch_owner']).to eq 'legacy'
    expect(request.evidence['migration_evidence']).to eq 'none'
    expect(request.evidence['account_age_seconds']).to eq 756
    expect(request.evidence.to_json).not_to include('raw-address-hash-secret')
    expect(request.evidence.to_json).not_to include('@')
    expect(request.evidence.to_json).not_to include('target_key_hash')
  end

  it 'reuses the pending request when screening is evaluated again' do
    stub_policies('follow_import' => 'always')
    batch = create_batch

    release(batch)
    original = ActionReviewRequest.last
    batch.update!(preflight_state: :screening)

    release(batch)

    expect(ActionReviewRequest.count).to eq 1
    expect(ActionReviewRequest.last.id).to eq original.id
    expect(batch.reload.review_required_preflight_state?).to be true
  end

  it 'does not release a review_required batch when policy later changes to off' do
    stub_policies('follow_import' => 'always')
    batch = create_batch
    release(batch)
    stub_policies('follow_import' => 'off')

    result = release(batch.reload)

    expect(result.released?).to be false
    expect(batch.reload.review_required_preflight_state?).to be true
    expect(ActionReviewRequest.count).to eq 1
    expect(ActionReviewRequest.last.pending_state?).to be true
  end

  it 'does not release a stopped batch' do
    stub_policies('follow_import' => 'always')
    batch = create_batch(preflight_state: :stopped)

    result = release(batch)

    expect(result.released?).to be false
    expect(batch.reload.stopped_preflight_state?).to be true
    expect(ActionReviewRequest.count).to eq 0
  end

  it 'does not re-evaluate a ready batch after policy changes to always' do
    stub_policies('follow_import' => 'always')
    batch = create_batch(preflight_state: :ready)

    result = release(batch)

    expect(result.released?).to be true
    expect(result.transitioned).to be false
    expect(batch.reload.ready_preflight_state?).to be true
    expect(ActionReviewRequest.count).to eq 0
  end

  it 'rolls back the request and leaves screening non-executable when the hold write fails' do
    stub_policies('follow_import' => 'always')
    batch = create_batch
    allow_any_instance_of(FollowImportBatch).to receive(:update!).and_wrap_original do |method, *args, **kwargs|
      attrs = kwargs.presence || (args.first.is_a?(Hash) ? args.first : {})
      raise ActiveRecord::StatementInvalid, 'state write failed' if attrs[:preflight_state].to_s == 'review_required'

      method.call(*args, **kwargs)
    end

    expect { release(batch) }.to raise_error(ActiveRecord::StatementInvalid, 'state write failed')
    expect(batch.reload.screening_preflight_state?).to be true
    expect(ActionReviewRequest.count).to eq 0
  end
end
