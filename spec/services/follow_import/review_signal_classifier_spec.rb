# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::ReviewSignalClassifier do # rubocop:disable Metrics/BlockLength
  subject(:classifier) { described_class.new }

  def classify(match, context = {})
    classifier.call({ 'cross_subject_best_match' => match }.merge(context))
  end

  def overlap_match(overlap:, stored:, reported:, extra: {})
    {
      'overlap_count' => overlap,
      'stored_linked_negative_target_count' => stored,
      'reported_linked_negative_target_count' => reported,
    }.merge(extra)
  end

  it 'returns none when there is no cross-subject match' do
    result = classify(nil)

    expect(result['classifier_version']).to eq described_class::VERSION
    expect(result['signal_level']).to eq 'none'
    expect(result['reason_codes']).to eq [described_class::REASON_NO_MATCH]
    expect(result['features']['conservative_negative_containment']).to be_nil
  end

  it 'returns none when overlap is below the low boundary' do
    result = classify(overlap_match(overlap: 4, stored: 4, reported: 4))

    expect(result['signal_level']).to eq 'none'
    expect(result['reason_codes']).to eq [described_class::REASON_BELOW]
  end

  it 'returns low at the exact low boundary' do
    result = classify(overlap_match(overlap: 5, stored: 100, reported: 100))

    expect(result['signal_level']).to eq 'low'
    expect(result['reason_codes']).to eq [described_class::REASON_LOW]
    expect(result['features']['conservative_negative_containment']).to be_within(1e-12).of(0.05)
  end

  it 'returns medium at the exact medium boundary' do
    result = classify(overlap_match(overlap: 25, stored: 125, reported: 125))

    expect(result['signal_level']).to eq 'medium'
    expect(result['reason_codes']).to eq [described_class::REASON_MEDIUM]
    expect(result['features']['conservative_negative_containment']).to be_within(1e-12).of(0.20)
  end

  it 'returns high at the exact high boundary' do
    result = classify(overlap_match(overlap: 100, stored: 200, reported: 200))

    expect(result['signal_level']).to eq 'high'
    expect(result['reason_codes']).to eq [described_class::REASON_HIGH]
    expect(result['features']['conservative_negative_containment']).to be_within(1e-12).of(0.50)
  end

  it 'keeps only the highest matching level' do
    result = classify(overlap_match(overlap: 231, stored: 355, reported: 355))

    expect(result['signal_level']).to eq 'high'
    expect(result['reason_codes']).to eq [described_class::REASON_HIGH]
  end

  it 'uses max(stored, reported) for conservative containment' do
    result = classify(overlap_match(overlap: 100, stored: 100, reported: 400, extra: { 'stored_negative_containment' => 1.0 }))

    expect(result['features']['conservative_negative_containment']).to be_within(1e-12).of(0.25)
    expect(result['signal_level']).to eq 'medium'
    expect(result['features']['stored_negative_containment']).to eq 1.0
  end

  it 'reaches a higher level only when the conservative lower bound clears it' do
    truncated = classify(overlap_match(
                           overlap: 100,
                           stored: 50,
                           reported: 1000,
                           extra: { 'stored_negative_containment' => 0.99, 'historical_fingerprint_complete' => false }
                         ))
    cleared = classify(overlap_match(
                         overlap: 100,
                         stored: 100,
                         reported: 200,
                         extra: { 'stored_negative_containment' => 1.0, 'historical_fingerprint_complete' => false }
                       ))

    expect(truncated['signal_level']).to eq 'low'
    expect(truncated['features']['conservative_negative_containment']).to be_within(1e-12).of(0.10)
    expect(cleared['signal_level']).to eq 'high'
    expect(cleared['features']['conservative_negative_containment']).to be_within(1e-12).of(0.50)
  end

  it 'does not emit medium or high when the reported count is missing' do
    result = classify(overlap_match(overlap: 1000, stored: 100, reported: nil, extra: { 'stored_negative_containment' => 1.0 }))

    expect(result['signal_level']).to eq 'low'
    expect(result['reason_codes']).to eq [described_class::REASON_LOW_UNKNOWN]
    expect(result['features']['conservative_negative_containment']).to be_nil
    expect(result['features']['reported_linked_negative_target_count']).to be_nil
  end

  it 'emits low for unknown completeness only at overlap 10 or more' do
    below = classify(overlap_match(overlap: 9, stored: 9, reported: nil))
    at = classify(overlap_match(overlap: 10, stored: nil, reported: nil))

    expect(below['signal_level']).to eq 'none'
    expect(below['reason_codes']).to eq [described_class::REASON_BELOW]
    expect(at['signal_level']).to eq 'low'
    expect(at['reason_codes']).to eq [described_class::REASON_LOW_UNKNOWN]
  end

  it 'does not let same-subject overlap raise the level' do
    context = {
      'same_subject_matching_snapshot_count' => 4,
      'same_subject_best_match' => overlap_match(overlap: 500, stored: 500, reported: 500),
    }
    result = classify(nil, context)

    expect(result['signal_level']).to eq 'none'
    expect(result['reason_codes']).to eq [described_class::REASON_NO_MATCH]
    expect(result['features']['same_subject_matching_snapshot_count']).to eq 4
  end

  it 'does not let action type, migration evidence, or current-target ratio change the level' do
    low = overlap_match(overlap: 5, stored: 100, reported: 100, extra: { 'current_target_overlap_ratio' => 0.0, 'action_types' => [] })
    varied = overlap_match(overlap: 5, stored: 100, reported: 100, extra: { 'current_target_overlap_ratio' => 1.0, 'action_types' => ['suspend'] })

    plain = classify(low, { 'migration_evidence' => 'none' })
    other = classify(varied, { 'migration_evidence' => 'strong' })

    expect(plain['signal_level']).to eq 'low'
    expect(other['signal_level']).to eq 'low'
    expect(other['features']['historical_action_types']).to eq ['suspend']
    expect(other['features']['migration_evidence']).to eq 'strong'
    expect(other['features']['current_target_overlap_ratio']).to eq 1.0
  end

  it 'drops identity-bearing match fields from normalized features' do
    result = classify(overlap_match(
                        overlap: 100,
                        stored: 200,
                        reported: 200,
                        extra: {
                          'snapshot_id' => 'snap-secret-99',
                          'historical_subject_id' => 'hist-subject-77',
                          'action_ids' => ['action-id-55'],
                          'target_key_hash' => 'target-hash-secret',
                          'action_types' => ['silence'],
                        }
                      ))

    expect(result['features'].keys).to match_array(described_class::FEATURE_KEYS)
    expect(result.to_json).not_to include('snap-secret-99')
    expect(result.to_json).not_to include('hist-subject-77')
    expect(result.to_json).not_to include('action-id-55')
    expect(result.to_json).not_to include('target-hash-secret')
    expect(result['features']['historical_action_types']).to eq ['silence']
  end
end
