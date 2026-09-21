# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Moderation::FollowImportNegativeTargetOverlapCohortService do
  let(:imported_at) { Time.utc(2026, 9, 21, 12, 0, 0) }
  let(:now) { Time.utc(2026, 9, 21, 15, 0, 0) }

  def stub_batch(id:, subject_id:, at: imported_at)
    FollowImportBatch.new.tap do |batch|
      batch.id = id
      batch.subject_id = subject_id
      batch.imported_at = at
    end
  end

  def overlap_result(batch, matches: [], **attrs)
    {
      'batch_id'                           => batch.id,
      'subject_id'                         => batch.subject_id,
      'as_of'                              => batch.imported_at,
      'target_rows'                        => attrs.fetch(:target_rows, 3),
      'comparable_unique_target_count'     => attrs.fetch(:comparable, 3),
      'unresolved_or_unmapped_target_rows' => attrs.fetch(:unresolved, 0),
      'candidate_snapshot_count'           => attrs.fetch(:candidates, 1),
      'matching_snapshot_count'            => matches.size,
      'matches'                            => matches,
    }
  end

  def match_row(same_subject:, overlap_count:, **attrs)
    snapshot_id = attrs.fetch(:snapshot_id, 1)
    complete = attrs.fetch(:complete, true)
    {
      'snapshot_id'                           => snapshot_id,
      'historical_subject_id'                 => attrs.fetch(:historical_subject_id, 9),
      'same_subject'                          => same_subject,
      'action_ids'                            => [100 + snapshot_id],
      'action_types'                          => ['suspend'],
      'latest_action_performed_at'            => imported_at - 1.day,
      'stored_linked_negative_target_count'   => 4,
      'reported_linked_negative_target_count' => complete.nil? ? nil : (complete ? 4 : 12),
      'historical_fingerprint_complete'       => complete,
      'overlap_count'                         => overlap_count,
      'current_target_overlap_ratio'          => attrs[:ratio] || (overlap_count / 4.0),
      'stored_negative_containment'           => attrs[:containment] || (overlap_count / 4.0),
      'jaccard'                               => attrs[:jaccard] || (overlap_count / 6.0),
    }
  end

  def cohort(results_by_id)
    batches = results_by_id.keys
    overlap = instance_double(Moderation::FollowImportNegativeTargetOverlapService)
    allow(overlap).to receive(:call) { |batch, **| results_by_id.fetch(batch) }
    described_class.new(overlap_service: overlap).call(batches, now: now)
  end

  def ledger_counts
    [
      ModerationSubject.count,
      ModerationInteractionEvent.count,
      ModerationRejectionEvent.count,
      ModerationAction.count,
      ModerationEvidenceSnapshot.count,
      FollowImportBatch.count,
      FollowImportTarget.count,
      Follow.count,
      Block.count,
      Mute.count,
    ]
  end

  describe 'de-duplication and unique subjects' do
    it 'counts a repeated batch id once and unique subjects correctly' do
      first = stub_batch(id: 1, subject_id: 10)
      repeat = stub_batch(id: 1, subject_id: 10)
      second = stub_batch(id: 2, subject_id: 10)
      third = stub_batch(id: 3, subject_id: 11)
      overlap = instance_double(Moderation::FollowImportNegativeTargetOverlapService)
      allow(overlap).to receive(:call) do |batch, **|
        overlap_result(batch, matches: [match_row(same_subject: false, overlap_count: 1, snapshot_id: batch.id)])
      end

      result = described_class.new(overlap_service: overlap).call([first, repeat, second, third], now: now)

      expect(result['batch_count']).to eq 3
      expect(result['subject_count']).to eq 2
      expect(result['rows'].map { |row| row['batch_id'] }).to eq [1, 2, 3]
      expect(overlap).to have_received(:call).exactly(3).times
    end
  end

  describe 'no-overlap rows stay in the cohort but leave distributions' do
    let(:with_overlap) { stub_batch(id: 1, subject_id: 10) }
    let(:without_overlap) { stub_batch(id: 2, subject_id: 11) }
    let(:result) do
      cohort(
        with_overlap => overlap_result(with_overlap, matches: [match_row(same_subject: false, overlap_count: 2)]),
        without_overlap => overlap_result(without_overlap, matches: [], candidates: 4)
      )
    end

    it 'keeps the no-overlap batch in rows and top-level counts' do
      expect(result['batch_count']).to eq 2
      expect(result['batches_with_any_overlap']).to eq 1
      expect(result['batches_with_cross_subject_overlap']).to eq 1
      expect(result['batches_with_same_subject_overlap']).to eq 0
      expect(result['rows'].size).to eq 2
      expect(result['rows'][1]['matching_snapshot_count']).to eq 0
      expect(result['rows'][1]['cross_subject']['best_match']).to be_nil
    end

    it 'excludes the no-overlap batch from best-match distributions' do
      cross_overlap = result.dig('distributions', 'cross_subject', 'overlap_count')
      same_overlap = result.dig('distributions', 'same_subject', 'overlap_count')

      expect(cross_overlap['n']).to eq 1
      expect(cross_overlap['excluded_n']).to eq 1
      expect(cross_overlap['min']).to eq 2
      expect(same_overlap['n']).to eq 0
      expect(same_overlap['excluded_n']).to eq 2
    end
  end

  describe 'same-subject vs cross-subject separation' do
    let(:batch) { stub_batch(id: 1, subject_id: 10) }
    let(:result) do
      cohort(
        batch => overlap_result(
          batch,
          matches: [
            match_row(same_subject: true, overlap_count: 3, snapshot_id: 21, historical_subject_id: 10),
            match_row(same_subject: false, overlap_count: 1, snapshot_id: 22, historical_subject_id: 99),
          ]
        )
      )
    end

    it 'separates same-subject and cross-subject matches without identity inference' do
      row = result['rows'].first

      expect(row['same_subject']['matching_snapshot_count']).to eq 1
      expect(row['same_subject']['best_match']['historical_subject_id']).to eq 10
      expect(row['cross_subject']['matching_snapshot_count']).to eq 1
      expect(row['cross_subject']['best_match']['historical_subject_id']).to eq 99
      expect(result['batches_with_same_subject_overlap']).to eq 1
      expect(result['batches_with_cross_subject_overlap']).to eq 1
      expect(row['same_subject']['best_match']).to_not have_key('same_person')
    end
  end

  describe 'deterministic best match' do
    it 'uses the first remaining row after the underlying service sort' do
      batch = stub_batch(id: 1, subject_id: 10)
      weaker = match_row(same_subject: false, overlap_count: 1, snapshot_id: 2)
      stronger = match_row(same_subject: false, overlap_count: 4, snapshot_id: 1)
      # Underlying service already sorts strongest overlap first.
      result = cohort(batch => overlap_result(batch, matches: [stronger, weaker]))

      expect(result['rows'].first.dig('cross_subject', 'best_match', 'snapshot_id')).to eq 1
      expect(result['rows'].first.dig('cross_subject', 'best_match', 'overlap_count')).to eq 4
    end
  end

  describe 'distribution math' do
    let(:a) { stub_batch(id: 1, subject_id: 10) }
    let(:b) { stub_batch(id: 2, subject_id: 11) }
    let(:c) { stub_batch(id: 3, subject_id: 12) }
    let(:d) { stub_batch(id: 4, subject_id: 13) }
    let(:e) { stub_batch(id: 5, subject_id: 14) }
    let(:result) do
      cohort(
        a => overlap_result(a, matches: [match_row(same_subject: false, overlap_count: 1, ratio: 0.1, containment: 0.2, jaccard: 0.05)]),
        b => overlap_result(b, matches: [match_row(same_subject: false, overlap_count: 2, ratio: 0.2, containment: 0.4, jaccard: 0.15)]),
        c => overlap_result(c, matches: [match_row(same_subject: false, overlap_count: 3, ratio: 0.3, containment: 0.6, jaccard: 0.25)]),
        d => overlap_result(d, matches: [match_row(same_subject: false, overlap_count: 4, ratio: 0.4, containment: 0.8, jaccard: 0.35)]),
        e => overlap_result(e, matches: [match_row(same_subject: false, overlap_count: 5, ratio: 0.5, containment: 1.0, jaccard: 0.45)])
      )
    end

    it 'summarizes overlap_count n/excluded_n/nonzero/min/max/mean and percentiles' do
      summary = result.dig('distributions', 'cross_subject', 'overlap_count')

      expect(summary['n']).to eq 5
      expect(summary['excluded_n']).to eq 0
      expect(summary['nonzero']).to eq 5
      expect(summary['min']).to eq 1
      expect(summary['max']).to eq 5
      expect(summary['mean']).to eq 3.0
      expect(summary['percentiles'][25]).to eq 2.0
      expect(summary['percentiles'][50]).to eq 3.0
      expect(summary['percentiles'][90]).to be_within(1e-9).of(4.6)
    end

    it 'summarizes ratio distributions from raw observed values' do
      ratio = result.dig('distributions', 'cross_subject', 'current_target_overlap_ratio')
      containment = result.dig('distributions', 'cross_subject', 'stored_negative_containment')
      jaccard = result.dig('distributions', 'cross_subject', 'jaccard')

      expect(ratio['mean']).to be_within(1e-9).of(0.3)
      expect(ratio['percentiles'][50]).to be_within(1e-9).of(0.3)
      expect(containment['min']).to be_within(1e-9).of(0.2)
      expect(containment['max']).to be_within(1e-9).of(1.0)
      expect(jaccard['n']).to eq 5
      expect(jaccard['excluded_n']).to eq 0
    end
  end

  describe 'fingerprint coverage' do
    it 'counts complete, incomplete, and unknown without converting unknown' do
      complete_batch = stub_batch(id: 1, subject_id: 10)
      incomplete_batch = stub_batch(id: 2, subject_id: 11)
      unknown_batch = stub_batch(id: 3, subject_id: 12)
      none_batch = stub_batch(id: 4, subject_id: 13)

      result = cohort(
        complete_batch => overlap_result(complete_batch, matches: [match_row(same_subject: true, overlap_count: 2, complete: true)]),
        incomplete_batch => overlap_result(incomplete_batch, matches: [match_row(same_subject: false, overlap_count: 2, complete: false)]),
        unknown_batch => overlap_result(unknown_batch, matches: [match_row(same_subject: false, overlap_count: 1, complete: nil)]),
        none_batch => overlap_result(none_batch, matches: [])
      )

      expect(result['coverage']['complete']).to eq 1
      expect(result['coverage']['incomplete']).to eq 1
      expect(result['coverage']['unknown']).to eq 1
      expect(result.dig('coverage', 'same_subject', 'complete')).to eq 1
      expect(result.dig('coverage', 'cross_subject', 'incomplete')).to eq 1
      expect(result.dig('coverage', 'cross_subject', 'unknown')).to eq 1
      expect(result.dig('coverage', 'same_subject', 'unknown')).to eq 0
    end
  end

  describe 'no look-ahead' do
    it 'analyzes each batch at imported_at via the underlying overlap service' do
      batch = stub_batch(id: 1, subject_id: 10, at: imported_at)
      overlap = instance_double(Moderation::FollowImportNegativeTargetOverlapService)
      expect(overlap).to receive(:call).with(batch, as_of: imported_at).and_return(overlap_result(batch))

      described_class.new(overlap_service: overlap).call([batch], now: now)
    end
  end

  describe 'empty cohort' do
    it 'returns a stable zero/empty shape' do
      result = described_class.new.call([], now: now)

      expect(result['generated_at']).to eq now.iso8601
      expect(result['batch_count']).to eq 0
      expect(result['subject_count']).to eq 0
      expect(result['batches_with_any_overlap']).to eq 0
      expect(result['batches_with_same_subject_overlap']).to eq 0
      expect(result['batches_with_cross_subject_overlap']).to eq 0
      expect(result['rows']).to eq []
      expect(result['coverage']).to include('complete' => 0, 'incomplete' => 0, 'unknown' => 0)
      expect(result.dig('distributions', 'same_subject', 'overlap_count', 'n')).to eq 0
      expect(result.dig('distributions', 'same_subject', 'overlap_count', 'excluded_n')).to eq 0
      expect(result.dig('distributions', 'cross_subject', 'jaccard', 'percentiles')[50]).to be_nil
      expect(result['elapsed_seconds']).to be >= 0
    end
  end

  describe 'end-to-end composition and read-only' do
    let(:importer) { Fabricate(:moderation_subject) }
    let(:other_subject) { Fabricate(:moderation_subject) }
    let(:target_a) { Fabricate(:moderation_subject) }
    let(:target_b) { Fabricate(:moderation_subject) }
    let(:target_c) { Fabricate(:moderation_subject) }

    def create_batch(subject, targets:, at: imported_at)
      batch = FollowImportBatch.create!(
        subject: subject,
        imported_at: at,
        mode: :merge,
        target_count: targets.size,
        resolved_target_count: targets.size,
        unresolved_target_count: 0
      )
      targets.each_with_index do |target, position|
        batch.targets.create!(target_subject: target, position: position)
      end
      batch
    end

    def create_moderated_snapshot(subject, linked_ids:, performed_at: imported_at - 1.day)
      snapshot = Fabricate(
        :moderation_evidence_snapshot,
        subject: subject,
        summary: { 'linked_negative_target_count' => linked_ids.size },
        fingerprint: { 'linked_negative_target_subject_ids' => linked_ids }
      )
      Fabricate(
        :moderation_action,
        subject: subject,
        evidence_snapshot: snapshot,
        action_type: :suspend,
        performed_at: performed_at
      )
      snapshot
    end

    it 'composes the real overlap service and does not write relationship or ledger rows' do
      overlapping = create_batch(importer, targets: [target_a, target_b, target_c])
      empty = create_batch(importer, targets: [target_c])
      create_moderated_snapshot(other_subject, linked_ids: [target_a.id, target_b.id])
      create_moderated_snapshot(other_subject, linked_ids: [target_a.id], performed_at: imported_at + 1.hour)

      result = nil
      expect { result = described_class.new.call([overlapping, empty], now: now) }.to_not(change { ledger_counts })

      expect(result['batch_count']).to eq 2
      expect(result['subject_count']).to eq 1
      expect(result['batches_with_cross_subject_overlap']).to eq 1
      expect(result['batches_with_same_subject_overlap']).to eq 0
      expect(result['rows'].first.dig('cross_subject', 'best_match', 'overlap_count')).to eq 2
      expect(result['rows'].last['matching_snapshot_count']).to eq 0
      expect(result).to_not have_key('later_suspended')
      expect(result).to_not have_key('future_moderation_action')
    end
  end
end
# rubocop:enable Metrics/BlockLength
