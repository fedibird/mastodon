# frozen_string_literal: true

require 'rails_helper'

describe PostProcessMediaWorker do # rubocop:disable Metrics/BlockLength
  subject(:worker) { described_class.new }

  let(:media) do
    allow(described_class).to receive(:perform_async)
    MediaAttachment.create!(
      account: Fabricate(:account),
      file: attachment_fixture('attachment.jpg'),
      delay_processing: true
    )
  end

  it 'stays on the ui queue consumed by the configured Sidekiq process' do
    options = described_class.get_sidekiq_options

    expect(options['queue']).to eq 'ui'
    expect(options['retry']).to eq 1
    expect(options['dead']).to be false
    expect(File.read(Rails.root.join('config/sidekiq.yml'))).to match(/^\s+- \[ui\]\s*$/)
    expect(File.read(Rails.root.join('Procfile.dev'))).to include('-q ui')
    expect(Admin::SystemCheck::SidekiqProcessCheck::SIDEKIQ_QUEUES).to include('ui')
  end

  it 'reprocesses every style for a still image and only the original for larger media' do
    calls = []
    allow_any_instance_of(Paperclip::Attachment).to receive(:reprocess!) do |_attachment, *args|
      calls << args
    end

    worker.perform(media.id)

    expect(calls).to eq [[]]
    expect(media.reload).to be_processing_complete

    calls.clear
    video = MediaAttachment.create!(
      account: media.account,
      file: attachment_fixture('attachment.jpg'),
      delay_processing: true
    )
    video.update_columns(type: MediaAttachment.types[:video], processing: MediaAttachment.processings[:queued])

    worker.perform(video.id)

    expect(calls).to eq [[:original]]
    expect(video.reload).to be_processing_complete
  end

  it 'does not process an attachment that is already complete' do
    media.update_columns(processing: MediaAttachment.processings[:complete])
    calls = []
    allow_any_instance_of(Paperclip::Attachment).to receive(:reprocess!) do |_attachment, *args|
      calls << args
    end

    expect(worker.perform(media.id)).to be true
    expect(calls).to eq []
    expect(media.reload).to be_processing_complete
  end

  it 'leaves the attachment in progress until retries are exhausted' do
    allow_any_instance_of(Paperclip::Attachment).to receive(:reprocess!).and_raise(Paperclip::Error, 'convert failed')

    2.times do
      expect { worker.perform(media.id) }.to raise_error(Paperclip::Error, 'convert failed')
      expect(media.reload).to be_processing_in_progress
    end

    described_class.sidekiq_retries_exhausted_block.call({ 'args' => [media.id], 'error_message' => 'convert failed' })

    expect(media.reload).to be_processing_failed
  end

  it 'ignores a missing attachment in perform and in the exhaustion callback' do
    expect(worker.perform(-1)).to be true
    expect { described_class.sidekiq_retries_exhausted_block.call({ 'args' => [-1], 'error_message' => 'missing' }) }.not_to raise_error
  end
end
