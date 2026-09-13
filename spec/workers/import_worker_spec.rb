# frozen_string_literal: true

require 'rails_helper'

describe ImportWorker do
  subject(:worker) { described_class.new }

  let(:account) { Fabricate(:account) }

  it 'keeps retry disabled so non-follow import semantics are unchanged' do
    expect(described_class.get_sidekiq_options['retry']).to be false
  end

  describe 'a follow import' do
    let(:import) { Import.create!(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt')) }

    it 'delegates to the retryable follow-import processor and does not touch the import itself' do
      allow(FollowImport::ProcessImportWorker).to receive(:perform_async)

      worker.perform(import.id)

      expect(FollowImport::ProcessImportWorker).to have_received(:perform_async).with(import.id)
      # Ownership handed off — ImportWorker neither runs the import nor destroys it.
      expect(FollowImportBatch.where(import_id: import.id)).to be_none
      expect(Import.exists?(import.id)).to be true
    end

    it 'drops the import when the processor could not even be enqueued' do
      allow(FollowImport::ProcessImportWorker).to receive(:perform_async).and_raise(StandardError, 'enqueue unavailable')

      expect { worker.perform(import.id) }.not_to raise_error

      expect(Import.exists?(import.id)).to be false
    end
  end

  describe 'a non-follow import' do
    let(:import) { Import.create!(account: account, type: 'blocking', data: attachment_fixture('imports.txt')) }

    it 'runs inline and destroys the import, without the follow-import processor' do
      service = instance_double(ImportService, call: nil)
      allow(ImportService).to receive(:new).and_return(service)
      allow(FollowImport::ProcessImportWorker).to receive(:perform_async)

      worker.perform(import.id)

      expect(service).to have_received(:call).with(import)
      expect(FollowImport::ProcessImportWorker).not_to have_received(:perform_async)
      expect(Import.exists?(import.id)).to be false
    end
  end
end
