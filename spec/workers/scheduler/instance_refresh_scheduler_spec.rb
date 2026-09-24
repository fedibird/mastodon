# frozen_string_literal: true

require 'rails_helper'

describe Scheduler::InstanceRefreshScheduler do
  subject { described_class.new }

  it 'refreshes instances and imports InstancesIndex when Chewy is enabled' do
    allow(Chewy).to receive(:enabled?).and_return(true)
    expect(Instance).to receive(:refresh).ordered
    expect(InstancesIndex).to receive(:import).ordered

    subject.perform
  end

  it 'refreshes instances without importing when Chewy is disabled' do
    allow(Chewy).to receive(:enabled?).and_return(false)
    expect(Instance).to receive(:refresh)
    expect(InstancesIndex).not_to receive(:import)

    subject.perform
  end
end
