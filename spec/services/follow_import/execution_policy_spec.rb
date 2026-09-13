# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::ExecutionPolicy do
  it 'exposes a single response_wait duration' do
    expect(described_class.response_wait).to be_a(ActiveSupport::Duration)
    expect(described_class.response_wait).to be > 0
  end

  it 'derives the response deadline from a given start time' do
    from = Time.utc(2026, 1, 1, 0, 0, 0)
    expect(described_class.response_deadline_at(from)).to eq(from + described_class.response_wait)
  end
end
