# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduler::Trends::RefreshScheduler do
  it 'refreshes trends when the setting is enabled' do
    Setting.trends = true
    allow(Trends).to receive(:refresh!)
    allow(Trends).to receive(:request_review!)

    described_class.new.perform

    expect(Trends).to have_received(:refresh!)
    expect(Trends).not_to have_received(:request_review!)
  end

  it 'does nothing when trends are disabled' do
    Setting.trends = false
    allow(Trends).to receive(:refresh!)

    described_class.new.perform

    expect(Trends).not_to have_received(:refresh!)
  end
end
