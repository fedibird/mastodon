# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowService, 'deferred distribution' do
  it 'continues a flush after a mid-flight failure without repeating finished steps' do
    source = Fabricate(:user).account
    target = Fabricate(:account, username: 'flushpal')
    local_calls = 0
    merge_calls = 0
    allow(LocalNotificationWorker).to receive(:perform_async) { local_calls += 1 }
    allow(MergeWorker).to receive(:perform_async) do
      merge_calls += 1
      raise RuntimeError, 'mid' if merge_calls == 1
    end
    service = described_class.new
    follow = service.call(source, target, defer_distribution: true)

    expect(local_calls).to eq 0
    expect(merge_calls).to eq 0
    expect { service.flush_distribution! }.to raise_error(RuntimeError, 'mid')
    expect(local_calls).to eq 1
    expect(merge_calls).to eq 1

    service.flush_distribution!
    expect(local_calls).to eq 1
    expect(merge_calls).to eq 2
    expect(source.following?(target)).to be true
    expect(follow).to be_persisted
  end

  it 'does not touch Redis or workers until flush, including an option change on an existing follow' do
    source = Fabricate(:user).account
    target = Fabricate(:account, username: 'already')
    source.follow!(target)
    expect(MergeWorker).not_to receive(:perform_async)
    expect(UnmergeWorker).not_to receive(:perform_async)
    expect(NotifyService).not_to receive(:new)

    described_class.new.call(source, target, defer_distribution: true, delivery: false)
  end
end
