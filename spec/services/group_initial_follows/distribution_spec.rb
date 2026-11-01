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
      target_locked: true,
      attempted_at: attempted_at
    )

    described_class.distribute_persisted!(follow,
      home_feed_partial_required: true, shadow_observation_required: true, shadow_target_locked: true, attempted_at: attempted_at)
  end

  it 'does not create another followed notification while replaying the same committed follow' do
    source = Fabricate(:user).account
    target = Fabricate(:account, username: 'noticereplay')
    follow = source.follow!(target)
    Notification.create!(account: source, activity: follow, type: 'followed')

    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(MergeWorker).to receive(:perform_async)
    expect_any_instance_of(NotifyService).to receive(:redeliver_existing!).with(instance_of(Notification))

    described_class.distribute_persisted!(follow)

    expect(Notification.where(account: source, activity: follow, type: 'followed').count).to eq 1
  end

  it 're-delivers Push on the existing notification if the first process died after save' do
    source = Fabricate(:user).account
    target = Fabricate(:account, username: 'pushreplay')
    follow = source.follow!(target)
    notification = Notification.create!(account: source, activity: follow, type: 'followed')

    pushed = []
    allow_any_instance_of(NotifyService).to receive(:push_notification!) { pushed << notification.id }
    allow_any_instance_of(NotifyService).to receive(:send_email!)
    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(MergeWorker).to receive(:perform_async)

    described_class.distribute_persisted!(follow)

    expect(Notification.where(account: source, activity: follow, type: 'followed').count).to eq 1
    expect(pushed).to eq [notification.id]
  end

  it 'sets the regeneration hint before enqueueing MergeWorker during a deferred flush' do
    source = Fabricate(:user).account
    target = Fabricate(:account, username: 'orderdeferred')
    service = described_class.new
    service.call(source, target, defer_distribution: true)

    expect(service).to receive(:mark_home_feed_as_partial!).ordered
    allow(LocalNotificationWorker).to receive(:perform_async)
    expect(MergeWorker).to receive(:perform_async).ordered
    allow(NotifyService).to receive(:new).and_return(double(call: nil))
    service.flush_distribution!
  end

  it 'sets the regeneration hint before enqueueing MergeWorker on recovery' do
    source = Fabricate(:user).account
    target = Fabricate(:account, username: 'orderrecover')
    follow = source.follow!(target)

    expect_any_instance_of(FollowService).to receive(:mark_home_feed_as_partial!).ordered
    allow(LocalNotificationWorker).to receive(:perform_async)
    expect(MergeWorker).to receive(:perform_async).ordered
    allow(NotifyService).to receive(:new).and_return(double(call: nil))
    described_class.distribute_persisted!(follow, home_feed_partial_required: true)
  end

  it 'retries Push using the saved notification when the first Push fails after insert' do
    source = Fabricate(:user).account
    target = Fabricate(:account, username: 'savedbeforepush')
    follow = source.follow!(target)

    allow_any_instance_of(NotifyService).to receive(:push_notification!).and_raise(RuntimeError, 'push interrupted')
    expect do
      NotifyService.new.call(source, 'followed', follow)
    end.to raise_error(RuntimeError, 'push interrupted')

    original = Notification.find_by!(account: source, activity: follow, type: 'followed')
    attempts = 0
    allow_any_instance_of(NotifyService).to receive(:push_notification!) { attempts += 1 }
    allow_any_instance_of(NotifyService).to receive(:send_email!)
    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(MergeWorker).to receive(:perform_async)

    described_class.distribute_persisted!(follow)

    expect(Notification.where(account: source, activity: follow, type: 'followed').pluck(:id)).to eq [original.id]
    expect(attempts).to eq 1
  end

  it 'uses the saved locked snapshot and original time for a shadow observation' do
    source = Fabricate(:user).account
    target = Fabricate(:account, username: 'laterlocked')
    observed_at = Time.utc(2026, 11, 1, 12, 0, 0)
    allow(Moderation::FollowGateShadowObserver).to receive(:enabled?).and_return(true)

    expect(Moderation::FollowGateShadowWorker).to receive(:perform_async).with(
      source.id,
      hash_including('target_locality' => 'local', 'target_locked' => true),
      observed_at.iso8601
    )
    Moderation::FollowGateShadowObserver.observe(
      source_account: source,
      target_account: target,
      target_locked: true,
      attempted_at: observed_at
    )
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
