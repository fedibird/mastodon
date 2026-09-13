# frozen_string_literal: true

require 'rails_helper'

# Regression: follow imports are executed asynchronously by
# FollowImport::BatchExecutionWorker, which re-reads the uploaded CSV to recover
# each target's address and options. ImportWorker must therefore NOT destroy the
# import before the executor has dispatched — otherwise the CSV vanishes and no
# one gets followed. The executor owns the import and destroys it once dispatch
# completes.
RSpec.describe 'Follow import CSV lifetime', type: :service do
  let!(:account) { Fabricate(:account) }
  let!(:bob)     { Fabricate(:account, username: 'bob') }
  let!(:eve)     { Fabricate(:account, username: 'eve', domain: 'example.com', protocol: :activitypub, inbox_url: 'https://example.com/inbox') }

  let(:import) { Import.create!(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt')) }

  before do
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
    allow(Import::RelationshipWorker).to receive(:perform_async)
  end

  it 'keeps the import for the executor, then the executor dispatches and destroys it' do
    ImportWorker.new.perform(import.id)

    batch = FollowImportBatch.find_by(import_id: import.id)
    expect(batch).to be_present
    expect(batch.targets.count).to eq 2
    # ImportWorker must NOT have destroyed the import — the executor still needs the CSV.
    expect(Import.exists?(import.id)).to be true
    expect(FollowImport::BatchExecutionWorker).to have_received(:perform_async).with(batch.id)

    FollowImport::BatchExecutionWorker.new.perform(batch.id)

    # The executor recovered the CSV, claimed the targets, and enqueued their follows...
    expect(Import::RelationshipWorker).to have_received(:perform_async).twice
    expect(batch.targets.where(state: :queued).count).to eq 2
    # ...then destroyed the import now that its addresses live in the enqueued jobs.
    expect(Import.exists?(import.id)).to be false
  end

  it 'still destroys a follow import whose batch recording failed (direct fallback enqueue)' do
    allow(Moderation::FollowImportRecorder).to receive(:record_batch).and_return(nil)
    allow(Import::RelationshipWorker).to receive(:push_bulk)

    ImportWorker.new.perform(import.id)

    expect(FollowImportBatch.where(import_id: import.id)).to be_none
    expect(Import.exists?(import.id)).to be false
  end

  it 'retries the executor handoff and succeeds on a later attempt using the same batch' do
    # The executor enqueue fails on the first attempt (e.g. Redis down) and
    # succeeds on the retry. The handoff bubbles rather than falling back to
    # another enqueue that shares the same failure dependency, so a retryable
    # ImportWorker can resume it.
    enqueued = []
    call = 0
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async) do |batch_id|
      call += 1
      raise StandardError, 'enqueue unavailable' if call == 1

      enqueued << batch_id
    end

    # First attempt bubbles; the import is retained (NOT destroyed on failure) so a
    # retry can reprocess it, and the batch has been recorded.
    expect { ImportWorker.new.perform(import.id) }.to raise_error(StandardError)

    batch = FollowImportBatch.find_by(import_id: import.id)
    expect(batch).to be_present
    expect(Import.exists?(import.id)).to be true
    expect(enqueued).to be_empty

    # Retry: same import, executor enqueue now succeeds, reusing the same batch
    # (idempotent by import_id — no duplicate batch); the import is retained for
    # the executor.
    expect { ImportWorker.new.perform(import.id) }.not_to raise_error

    expect(enqueued).to eq [batch.id]
    expect(FollowImportBatch.where(import_id: import.id).count).to eq 1
    expect(Import.exists?(import.id)).to be true
  end
end
