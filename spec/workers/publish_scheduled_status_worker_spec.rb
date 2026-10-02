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
