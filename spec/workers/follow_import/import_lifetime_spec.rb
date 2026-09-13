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

  it 'falls back to a direct enqueue when the executor handoff fails, without leaking the import or losing follows' do
    # Batch recording succeeds, but enqueuing the executor raises (e.g. Redis down).
    # ImportWorker has retry: false and retains follow imports that have a batch, so
    # a lost executor job would strand the import + CSV + all pending targets.
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async).and_raise(StandardError, 'enqueue unavailable')
    # Clean inline CSV (no trailing blank row) so the fallback's generic
    # import_relationships! loop enqueues both follows; a trailing blank row trips
    # its pre-existing `return if key.blank?` guard, which is unrelated here.
    allow_any_instance_of(ImportService).to receive(:import_data).and_return("Account address,Show boosts\nbob,true\neve@example.com,false")

    captured = []
    allow(Import::RelationshipWorker).to receive(:perform_async) { |*args| captured << args }
    allow(Import::RelationshipWorker).to receive(:push_bulk) { |items, &block| items.each { |item| captured << block.call(item) } }

    expect { ImportWorker.new.perform(import.id) }.not_to raise_error

    batch = FollowImportBatch.find_by(import_id: import.id)
    expect(batch).to be_present

    # The follows were NOT lost — they were enqueued directly and correlated to
    # the recorded targets so those still settle.
    follow_args = captured.select { |args| args[2] == 'follow' }
    expect(follow_args.size).to eq 2
    expect(follow_args.map { |args| args[3]['follow_import_target_id'] }).to match_array(batch.targets.map(&:id))

    # The import (raw CSV) was NOT leaked.
    expect(Import.exists?(import.id)).to be false
  end
end
