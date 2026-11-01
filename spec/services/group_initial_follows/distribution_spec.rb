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

  it 'replays the empty-home hint and shadow observation for a committed follow' do
    source = Fabricate(:user).account
    target = Fabricate(:account, username: 'shadowreplay')
    follow = source.follow!(target)
    attempted_at = Time.utc(2026, 11, 1, 10, 0, 0)
    service = described_class.new

    allow(described_class).to receive(:new).and_return(service)
    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(MergeWorker).to receive(:perform_async)
    allow(NotifyService).to receive(:new).and_return(double(call: nil))
    expect(service).to receive(:mark_home_feed_as_partial!).once
    expect(Moderation::FollowGateShadowObserver).to receive(:observe).with(
      source_account: source,
      target_account: target,
      mechanism: nil,
      attempted_at: attempted_at
    )

    described_class.distribute_persisted!(follow, home_feed_partial_required: true, attempted_at: attempted_at)
  end

  it 'does not create another followed notification while replaying the same committed follow' do
    source = Fabricate(:user).account
    target = Fabricate(:account, username: 'noticereplay')
    follow = source.follow!(target)
    Notification.create!(account: source, activity: follow, type: 'followed')

    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(MergeWorker).to receive(:perform_async)
    expect(NotifyService).not_to receive(:new)

    described_class.distribute_persisted!(follow)

    expect(Notification.where(account: source, activity: follow, type: 'followed').count).to eq 1
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
