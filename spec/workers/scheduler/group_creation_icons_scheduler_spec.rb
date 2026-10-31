# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduler::GroupCreationIconsScheduler do
  it 'is on the hourly scheduler queue' do
    schedule = File.read(Rails.root.join('config/sidekiq.yml'))

    expect(schedule).to include('class: Scheduler::GroupCreationIconsScheduler')
    expect(schedule).to match(/group_creation_icons_scheduler:\n\s+every: '1h'\n\s+class: Scheduler::GroupCreationIconsScheduler\n\s+queue: scheduler/)
  end

  it 'retries terminal purges and approved icon handoff when the sweep raises' do
    allow(GroupCreationIcons::Sweep).to receive(:call).and_raise(RuntimeError, 'disk')
    expect(GroupCreationIcons::Purge).to receive(:purge_terminal).and_return(purged: 0, failed: 0)
    expect(GroupCreationIcons::HandoffRecovery).to receive(:call).and_return(finished: 0, pending: 0, failed: 0)

    described_class.new.perform
  end
end
