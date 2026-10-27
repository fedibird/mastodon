# frozen_string_literal: true

require 'rails_helper'

describe Scheduler::ExternalBridgeRSSMediaGcScheduler do
  it 'does not enqueue work or delete an unattached upload when nothing is due' do
    upload = nil
    Tempfile.create(['compose', '.png']) do |file|
      file.binmode
      file.write(Rails.root.join('spec', 'fixtures', 'files', 'emojo.png').binread)
      file.rewind
      upload = MediaAttachment.create!(account: Fabricate(:account), file: file)
    end
    upload.update_columns(created_at: 10.days.ago)

    expect(ExternalBridge::RSS::MediaGcWorker).not_to receive(:perform_async)
    described_class.new.perform

    expect(upload.reload).to be_persisted
  end
end
