# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::ProgressService do
  subject(:service) { described_class.new }

  let(:batch) do
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  def target_in(state, position)
    batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: position, state: state)
  end

  describe 'aggregating states' do
    before do
      target_in(:pending, 0)
      target_in(:awaiting_response, 1)
      target_in(:accepted, 2)
      target_in(:rejected, 3)
      target_in(:completed_no_response, 4)
      target_in(:delivery_failed, 5)
    end

    it 'counts each state and derives processed / remaining' do
      result = service.call(batch)

      expect(result['batch_id']).to eq batch.id
      expect(result['total']).to eq 6
      expect(result['pending']).to eq 1
      expect(result['awaiting_response']).to eq 1
      expect(result['accepted']).to eq 1
      expect(result['rejected']).to eq 1
      expect(result['completed_no_response']).to eq 1
      expect(result['delivery_failed']).to eq 1
      # terminal = accepted + rejected + completed_no_response + delivery_failed
      expect(result['processed']).to eq 4
      expect(result['remaining']).to eq 2
      expect(result['completed']).to be false
    end
  end

  describe 'completion' do
    it 'is completed only when every target is terminal' do
      target_in(:accepted, 0)
      target_in(:rejected, 1)
      target_in(:delivery_failed, 2)

      result = service.call(batch)
      expect(result['total']).to eq 3
      expect(result['processed']).to eq 3
      expect(result['remaining']).to eq 0
      expect(result['completed']).to be true
    end

    it 'is not completed while a non-terminal target remains' do
      target_in(:accepted, 0)
      target_in(:awaiting_response, 1)

      expect(service.call(batch)['completed']).to be false
    end
  end

  describe 'empty batch' do
    it 'reports zeros and completed false (nothing to complete)' do
      result = service.call(batch)

      expect(result['total']).to eq 0
      expect(result['processed']).to eq 0
      expect(result['remaining']).to eq 0
      expect(result['completed']).to be false
    end
  end

  it 'accepts a batch id as well as a batch record' do
    target_in(:accepted, 0)
    expect(service.call(batch.id)['accepted']).to eq 1
  end

  describe '#user_summary' do
    before do
      target_in(:pending, 0)           # waiting
      target_in(:awaiting_response, 1) # waiting
      target_in(:accepted, 2)          # processed
      target_in(:rejected, 3)          # processed
      target_in(:delivery_failed, 4)   # processed + failed
    end

    it 'exposes only coarse buckets (no internal state / gate / risk detail)' do
      summary = service.user_summary(batch)

      expect(summary.keys).to match_array(%w(total processed waiting failed completed preparing))
      expect(summary['preparing']).to be false
      expect(summary['total']).to eq 5
      expect(summary['processed']).to eq 3
      expect(summary['waiting']).to eq 2
      expect(summary['failed']).to eq 2 # rejected + delivery_failed; completed_no_response is not a failure
      expect(summary['completed']).to be false
    end

    it 'counts rejected as failed (could not be followed) and leaves completed_no_response neutral' do
      batch.targets.delete_all
      target_in(:accepted, 0)
      target_in(:rejected, 1)
      target_in(:completed_no_response, 2)

      summary = service.user_summary(batch)

      expect(summary['total']).to eq 3
      expect(summary['processed']).to eq 3
      expect(summary['failed']).to eq 1
      expect(summary['completed']).to be true
    end

    it 'reports completed when every target is terminal' do
      batch.targets.where(state: %i(pending awaiting_response)).update_all(state: FollowImportTarget.states[:accepted])

      expect(service.user_summary(batch)['completed']).to be true
    end
  end

  describe '#preparing_summary' do
    it 'never treats a pre-batch import as completed and leaves counts unknown' do
      summary = service.preparing_summary

      expect(summary['preparing']).to be true
      expect(summary['completed']).to be false
      expect(summary['total']).to be_nil
      expect(summary['waiting']).to be_nil
    end
  end
end
