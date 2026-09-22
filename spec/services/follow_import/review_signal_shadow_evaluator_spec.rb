# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::ReviewSignalShadowEvaluator do # rubocop:disable Metrics/BlockLength
  let(:observation_service) { instance_double(Moderation::FollowImportRecurrenceObservationService) }
  let(:clock) { -> { Time.utc(2026, 9, 21, 18, 0, 0) } }
  let(:evaluator) { described_class.new(observation_service: observation_service, clock: clock) }
  let(:imported_at) { Time.utc(2026, 9, 20, 12, 0, 0) }
  let(:batch) do
    FollowImportBatch.create!(
      subject: ModerationSubject.for_account!(Fabricate(:account)),
      imported_at: imported_at,
      mode: :merge,
      dispatch_owner: :scheduler,
      dispatch_cohort: :operational,
      migration_evidence: :none,
      account_age_seconds: 12_345,
      target_count: 2,
      resolved_target_count: 2,
      unresolved_target_count: 0
    )
  end

  def cross_match
    {
      'snapshot_id' => 'snap-secret-99',
      'historical_subject_id' => 'hist-subject-77',
      'action_ids' => ['action-id-55'],
      'action_types' => ['suspend'],
      'latest_action_performed_at' => Time.utc(2026, 9, 1, 8, 0, 0),
      'historical_fingerprint_complete' => true,
      'stored_linked_negative_target_count' => 200,
      'reported_linked_negative_target_count' => 200,
      'overlap_count' => 100,
      'current_target_overlap_ratio' => 0.25,
      'stored_negative_containment' => 0.5,
      'jaccard' => 0.1,
      'target_key_hash' => 'target-hash-secret',
      'acct' => 'secret@example.com',
    }
  end

  def campaign_for(match, batch_count: 2)
    {
      'campaign_key' => 'campaign-secret-key',
      'batch_count' => batch_count,
      'target_rows' => 40,
      'comparable_unique_target_count' => 36,
      'unresolved_or_unmapped_target_rows' => 4,
      'same_subject' => {
        'matching_snapshot_count' => 3,
        'best_match' => {
          'overlap_count' => 999,
          'snapshot_id' => 'same-snap-secret',
          'stored_linked_negative_target_count' => 999,
          'reported_linked_negative_target_count' => 999,
        },
      },
      'cross_subject' => {
        'matching_snapshot_count' => match.nil? ? 0 : 1,
        'best_match' => match,
      },
    }
  end

  def stub_observation(latest, available: true)
    allow(observation_service).to receive(:call) do |subject, now:, lookback:, max_gap:|
      expect(subject).to eq batch.subject
      expect(now).to eq batch.imported_at
      expect(lookback).to eq Moderation::FollowImportRecurrenceObservationService::DEFAULT_LOOKBACK
      expect(max_gap).to eq Moderation::FollowImportRecurrenceObservationService::DEFAULT_MAX_GAP
      {
        'available' => available,
        'reason' => available ? nil : 'no_follow_import_batches_in_lookback',
        'subject_id' => 'subject-secret-token',
        'latest_campaign' => latest,
        'previous_campaign' => campaign_for(cross_match.merge('overlap_count' => 1), batch_count: 99),
        'notes' => ['not stored'],
      }
    end
  end

  it 'classifies the latest campaign cross-subject match as of the import instant' do
    stub_observation(campaign_for(cross_match))

    payload = evaluator.call(batch)

    expect(payload['schema_version']).to eq 1
    expect(payload['classifier_version']).to eq FollowImport::ReviewSignalClassifier::VERSION
    expect(payload['evaluation_status']).to eq 'ok'
    expect(payload['evaluated_at']).to eq clock.call.iso8601
    expect(payload['as_of']).to eq batch.imported_at.utc.iso8601
    expect(payload['as_of']).not_to eq payload['evaluated_at']
    expect(payload['signal_level']).to eq 'high'
    expect(payload['reason_codes']).to eq [FollowImport::ReviewSignalClassifier::REASON_HIGH]
    expect(payload['features']['campaign_batch_count']).to eq 2
    expect(payload['features']['overlap_count']).to eq 100
    expect(payload['features']['conservative_negative_containment']).to be_within(1e-12).of(0.50)
    expect(payload['features']['historical_fingerprint_complete']).to be true
    expect(payload['features']['historical_action_types']).to eq ['suspend']
    expect(payload['features']['latest_historical_action_performed_at']).to eq Time.utc(2026, 9, 1, 8, 0, 0).iso8601
    expect(payload['features']['same_subject_matching_snapshot_count']).to eq 3
    expect(payload['features']['cross_subject_matching_snapshot_count']).to eq 1
    expect(payload['features']['mode']).to eq 'merge'
    expect(payload['features']['dispatch_owner']).to eq 'scheduler'
    expect(payload['features']['account_age_seconds']).to eq 12_345
    expect(payload['features'].keys).to match_array(FollowImport::ReviewSignalClassifier::FEATURE_KEYS)
    encoded = payload.to_json
    expect(encoded).not_to include('snap-secret-99')
    expect(encoded).not_to include('hist-subject-77')
    expect(encoded).not_to include('action-id-55')
    expect(encoded).not_to include('target-hash-secret')
    expect(encoded).not_to include('secret@example.com')
    expect(encoded).not_to include('same-snap-secret')
    expect(encoded).not_to include('campaign-secret-key')
    expect(encoded).not_to include('subject-secret-token')
    expect(encoded).not_to include('not stored')
  end

  it 'does not use the same-subject match when the cross-subject match is absent' do
    stub_observation(campaign_for(nil))

    payload = evaluator.call(batch)

    expect(payload['signal_level']).to eq 'none'
    expect(payload['reason_codes']).to eq [FollowImport::ReviewSignalClassifier::REASON_NO_MATCH]
    expect(payload['features']['overlap_count']).to be_nil
    expect(payload['features']['same_subject_matching_snapshot_count']).to eq 3
  end

  it 'returns a factual none result when recurrence observation is unavailable' do
    stub_observation(nil, available: false)

    payload = evaluator.call(batch)

    expect(payload['evaluation_status']).to eq 'ok'
    expect(payload['signal_level']).to eq 'none'
    expect(payload['reason_codes']).to eq [described_class::REASON_UNAVAILABLE]
    expect(payload['as_of']).to eq batch.imported_at.utc.iso8601
    expect(payload.to_json).not_to include('subject-secret-token')
  end

  it 'does not fabricate a signal when classification raises' do
    stub_observation(campaign_for(cross_match))
    classifier = instance_double(FollowImport::ReviewSignalClassifier)
    allow(classifier).to receive(:call).and_raise(RuntimeError, 'classifier failed')
    raising = described_class.new(observation_service: observation_service, classifier: classifier, clock: clock)

    expect { raising.call(batch) }.to raise_error(RuntimeError, 'classifier failed')
  end
end
