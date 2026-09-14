# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::ProcessImportWorker do
  subject(:worker) { described_class.new }

  let(:account) { Fabricate(:account) }

  def create_follow_import(overwrite: false, pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION)
    Import.create!(
      account: account,
      type: 'following',
      overwrite: overwrite,
      data: attachment_fixture('new-following-imports.txt'),
      follow_import_pipeline_version: pipeline_version
    )
  end

  before do
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
    allow(Import::RelationshipWorker).to receive(:perform_async)
  end

  it 'records a batch and hands a marked import to the executor' do
    import = create_follow_import

    worker.perform(import.id)

    batch = FollowImportBatch.find_by(import_id: import.id)
    expect(batch).to be_present
    expect(FollowImport::BatchExecutionWorker).to have_received(:perform_async).with(batch.id)
    expect(Import.exists?(import.id)).to be true
  end

  it 'does not call ImportService for an unmarked leftover follow import' do
    import = create_follow_import(pipeline_version: nil)
    allow(ImportService).to receive(:new)

    worker.perform(import.id)

    expect(ImportService).not_to have_received(:new)
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    expect(FollowImportBatch.where(import_id: import.id)).to be_none
    expect(Import.exists?(import.id)).to be true
  end

  it 'does not start follow or unfollow work when an unmarked overwrite import reaches the worker' do
    extra = Fabricate(:account, username: 'already_followed')
    account.follow!(extra)
    import = create_follow_import(overwrite: true, pipeline_version: nil)

    allow(ImportService).to receive(:new)
    allow(FollowService).to receive(:new)
    allow(UnfollowService).to receive(:new)

    worker.perform(import.id)

    expect(ImportService).not_to have_received(:new)
    expect(FollowService).not_to have_received(:new)
    expect(UnfollowService).not_to have_received(:new)
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    expect(account.following?(extra)).to be true
    expect(Import.exists?(import.id)).to be true
  end
end
