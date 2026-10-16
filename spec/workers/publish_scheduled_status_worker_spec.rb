# frozen_string_literal: true

require 'rails_helper'

describe PublishScheduledStatusWorker do
  subject { described_class.new }

  let(:scheduled_status) { Fabricate(:scheduled_status, params: { text: 'Hello world, future!' }) }

  describe 'perform' do
    before do
      subject.perform(scheduled_status.id)
    end

    it 'creates a status' do
      expect(scheduled_status.account.statuses.first.text).to eq 'Hello world, future!'
    end

    it 'removes the scheduled status' do
      expect(ScheduledStatus.find_by(id: scheduled_status.id)).to be_nil
    end
  end

  it 'rejects an existing scheduled whitespace-only post above the current limit with media' do
    account = Fabricate(:account)
    media = MediaAttachment.create!(account: account, type: :image, file_file_name: 'test.jpg', file_content_type: 'image/jpeg', file_file_size: 1)
    text = ' ' * (StatusLengthValidator::MAX_CHARS + 1)
    scheduled = Fabricate(:scheduled_status, account: account, params: { text: text, media_ids: [media.id] })
    allow(DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)

    subject.perform(scheduled.id)

    expect(account.statuses).to be_empty
    expect(media.reload.status_id).to be_nil
    expect(scheduled.params['text']).to eq text
    expect(DistributionWorker).not_to have_received(:perform_async)
    expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async)
  end

  it 'uses the same publish barrier when the scheduled text has an unresolved redirect' do
    scheduled = Fabricate(:scheduled_status, params: { text: 'later https://bit.ly/scheduled' })
    allow(StatusPublishPreparationWorker).to receive(:perform_async)
    allow(DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
    expect(Request).not_to receive(:new)

    subject.perform(scheduled.id)

    status = scheduled.account.statuses.find_by!(text: 'later https://bit.ly/scheduled')
    expect(StatusPublishPreparationWorker).to have_received(:perform_async).with(status.id)
    expect(DistributionWorker).not_to have_received(:perform_async)
    expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async)
    expect(StatusPublishPreparationService.new.marked?(status)).to be true
  end
end
