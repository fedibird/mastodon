# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::Telemetry do
  it 'swallows transport insert failures and logs a warning' do
    allow(FollowImportTransportObservation).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')
    allow(Rails.logger).to receive(:warn)

    expect(
      described_class.record_transport(
        phase: 'resolve_account',
        outcome: 'resolved',
        started_at: Time.now.utc,
        finished_at: Time.now.utc
      )
    ).to be_nil

    expect(Rails.logger).to have_received(:warn).with(/FollowImport::Telemetry.*transport/)
  end

  it 'swallows dispatch insert failures and logs a warning' do
    allow(FollowImportDispatchObservation).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')
    allow(Rails.logger).to receive(:warn)

    expect(described_class.record_dispatch(candidate_count: 1, claimed_count: 1, pending_count: 0)).to be_nil
    expect(Rails.logger).to have_received(:warn).with(/FollowImport::Telemetry.*dispatch/)
  end
end
