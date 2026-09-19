# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::ReportSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        report,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  let(:report) { Fabricate(:report) }

  it 'returns action_taken as false for an unresolved report' do
    expect(json[:action_taken]).to eq false
  end

  it 'returns action_taken as true for a resolved report' do
    report.resolve!(Fabricate(:account))

    expect(json[:action_taken]).to eq true
  end

  it 'does not expose action_taken_at' do
    expect(json).to_not have_key(:action_taken_at)
  end
end

RSpec.describe REST::Admin::ReportSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        report,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  let(:report) { Fabricate(:report) }

  it 'returns action_taken as a boolean' do
    expect(json[:action_taken]).to eq false

    report.resolve!(Fabricate(:account))

    expect(json[:action_taken]).to eq true
  end

  it 'does not expose action_taken_at yet' do
    expect(json).to_not have_key(:action_taken_at)
  end
end
