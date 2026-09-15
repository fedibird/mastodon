# frozen_string_literal: true

require 'rails_helper'

# Follow imports are processed by the retryable FollowImport::ProcessImportWorker
# (records the batch + hands off to the executor). The executor
# (FollowImport::BatchExecutionWorker) re-reads the uploaded CSV to recover each
# target's address/options, so the import must NOT be destroyed before dispatch
# completes — the executor owns the import and destroys it when done.
RSpec.describe 'Follow import CSV lifetime', type: :service do
  let!(:account) { Fabricate(:account) }
  let!(:bob)     { Fabricate(:account, username: 'bob') }
  let!(:eve)     { Fabricate(:account, username: 'eve', domain: 'example.com', protocol: :activitypub, inbox_url: 'https://example.com/inbox') }

  let(:import) do
    Import.create!(
      account: account,
      type: 'following',
      data: attachment_fixture('new-following-imports.txt'),
      follow_import_pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION
    )
  end

  before do
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
    allow(Import::RelationshipWorker).to receive(:perform_async)
  end

  it 'keeps the import for the executor, then the executor dispatches and destroys it' do
    FollowImport::ProcessImportWorker.new.perform(import.id)

    batch = FollowImportBatch.find_by(import_id: import.id)
    expect(batch).to be_present
    expect(batch.targets.count).to eq 2
    # The processor must NOT have destroyed the import — the executor still needs the CSV.
    expect(Import.exists?(import.id)).to be true
    expect(FollowImport::BatchExecutionWorker).to have_received(:perform_async).with(batch.id)

    FollowImport::BatchExecutionWorker.new.perform(batch.id)

    # The executor recovered the CSV, claimed the targets, and enqueued their follows...
    expect(Import::RelationshipWorker).to have_received(:perform_async).twice
    expect(batch.targets.where(state: :queued).count).to eq 2
    # ...then destroyed the import now that its addresses live in the enqueued jobs.
    expect(Import.exists?(import.id)).to be false
  end

  it 'destroys a follow import whose batch recording failed (direct fallback enqueue)' do
    allow(Moderation::FollowImportRecorder).to receive(:record_batch).and_return(nil)
    allow(Import::RelationshipWorker).to receive(:push_bulk)

    FollowImport::ProcessImportWorker.new.perform(import.id)

    expect(FollowImportBatch.where(import_id: import.id)).to be_none
    expect(Import.exists?(import.id)).to be false
  end

  it 'retries the executor handoff and succeeds on a later attempt using the same batch' do
    # The executor enqueue fails on the first attempt (e.g. Redis down) and
    # succeeds on the retry. The handoff bubbles rather than falling back to another
    # enqueue that shares the same failure dependency, so the retryable processor
    # can resume it.
    enqueued = []
    call = 0
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async) do |batch_id|
      call += 1
      raise StandardError, 'enqueue unavailable' if call == 1

      enqueued << batch_id
    end

    # First attempt bubbles; the import is retained (NOT destroyed on failure) so a
    # retry can reprocess it, and the batch has been recorded.
    expect { FollowImport::ProcessImportWorker.new.perform(import.id) }.to raise_error(StandardError)

    batch = FollowImportBatch.find_by(import_id: import.id)
    expect(batch).to be_present
    expect(Import.exists?(import.id)).to be true
    expect(enqueued).to be_empty

    # Retry: same import, executor enqueue now succeeds, reusing the same batch
    # (idempotent by import_id — no duplicate batch); the import is retained for
    # the executor.
    expect { FollowImport::ProcessImportWorker.new.perform(import.id) }.not_to raise_error

    expect(enqueued).to eq [batch.id]
    expect(FollowImportBatch.where(import_id: import.id).count).to eq 1
    expect(Import.exists?(import.id)).to be true
  end

  it 'retains the import on retries-exhausted when a post-handoff step fails after the executor was enqueued' do
    # Dual-write race: the executor enqueue succeeds (a BatchExecutionWorker job is
    # queued), but a later step fails repeatedly until retries exhaust. The cleanup
    # must NOT delete the CSV, or that already-queued executor would run without it.
    # (Representative later-step failure: the overwrite-removal enqueue.)
    carol = Fabricate(:account, username: 'carol')
    account.follow!(carol) # not in the import CSV, so overwrite tries to unfollow her
    import.update!(overwrite: true)

    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async) # succeeds: executor enqueued
    allow(Import::RelationshipWorker).to receive(:perform_async).and_raise(StandardError, 'unfollow enqueue unavailable')

    expect { FollowImport::ProcessImportWorker.new.perform(import.id) }.to raise_error(StandardError)
    expect(FollowImportBatch.exists?(import_id: import.id)).to be true

    # Simulate Sidekiq exhausting all retries.
    FollowImport::ProcessImportWorker.sidekiq_retries_exhausted_block.call('args' => [import.id])

    # A batch exists, so the CSV is conservatively retained for the (possibly
    # already queued) executor.
    expect(Import.exists?(import.id)).to be true
  end

  it 'retains the import on retries-exhausted whenever a batch exists (absence of a marker cannot prove no executor job)' do
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async).and_raise(StandardError, 'enqueue unavailable')

    expect { FollowImport::ProcessImportWorker.new.perform(import.id) }.to raise_error(StandardError)
    expect(FollowImportBatch.exists?(import_id: import.id)).to be true

    FollowImport::ProcessImportWorker.sidekiq_retries_exhausted_block.call('args' => [import.id])

    expect(Import.exists?(import.id)).to be true
  end

  it 'retains the import on retries-exhausted even with no batch while another processor is still pending' do
    # Watchdog recovery (and ambiguous enqueues) can leave multiple
    # ProcessImportWorker retry chains for the same import before a batch is
    # recorded. One chain exhausting must not delete the CSV the sibling needs.
    expect(FollowImportBatch.where(import_id: import.id)).to be_none

    FollowImport::ProcessImportWorker.sidekiq_retries_exhausted_block.call('args' => [import.id])

    expect(Import.exists?(import.id)).to be true
    expect(FollowImportBatch.where(import_id: import.id)).to be_none

    # The still-pending processor can still read the CSV and record the batch.
    FollowImport::ProcessImportWorker.new.perform(import.id)

    expect(FollowImportBatch.exists?(import_id: import.id)).to be true
    expect(Import.exists?(import.id)).to be true
  end
end
