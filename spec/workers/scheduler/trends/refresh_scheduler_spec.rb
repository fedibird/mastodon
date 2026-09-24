# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduler::Trends::RefreshScheduler do
  it 'refreshes trends when the setting is enabled' do
    Setting.trends = true
    allow(Trends).to receive(:refresh!)
    allow(TrendingTags).to receive(:notify_unreviewed!)

    described_class.new.perform

    expect(Trends).to have_received(:refresh!)
    expect(TrendingTags).to have_received(:notify_unreviewed!)
  end

  it 'does nothing when trends are disabled' do
    Setting.trends = false
    allow(Trends).to receive(:refresh!)

    described_class.new.perform

    expect(Trends).not_to have_received(:refresh!)
  end
end
