# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::DispatchCounts do
  def create_batch
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  it 'counts pending targets per batch and globally without loading accounts' do
    first = create_batch
    second = create_batch
    first.targets.create!(target_key_hash: 'a', position: 0)
    first.targets.create!(target_key_hash: 'b', position: 1, state: :queued)
    second.targets.create!(target_key_hash: 'c', position: 0)

    expect(described_class.pending_for(first)).to eq 1
    expect(described_class.global_pending).to eq 2
    expect(described_class.active_batches).to eq 2
  end

  it 'returns 0 when a set is observed empty' do
    batch = create_batch
    expect(described_class.pending_for(batch)).to eq 0
  end

  it 'returns nil when a count cannot be measured' do
    batch = create_batch
    allow(batch).to receive(:targets).and_raise(ActiveRecord::StatementInvalid, 'boom')
    allow(FollowImportTarget).to receive(:where).and_raise(ActiveRecord::StatementInvalid, 'boom')

    expect(described_class.pending_for(batch)).to be_nil
    expect(described_class.global_pending).to be_nil
    expect(described_class.active_batches).to be_nil
  end
end
