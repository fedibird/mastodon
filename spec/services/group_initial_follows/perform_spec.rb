# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupInitialFollows::Perform do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  around do |example|
    previous = Setting.group_creation_requests
    Setting.group_creation_requests = true
    example.run
  ensure
    Setting.group_creation_requests = previous
  end

  let(:requester) { Fabricate(:user, account: Fabricate(:account, username: 'ownerperson')) }
  let(:reviewer) { user_with_role('Owner') }

  def submit(username)
    GroupCreationRequest.create!(
      requester_account: requester.account,
      username: username,
      display_name: username,
      note: 'A local group'
    )
  end

  def approve_without_running(username)
    request = submit(username)
    allow(GroupInitialFollows::Worker).to receive(:perform_async)
    result = GroupCreationRequests::ApproveService.call(request: request, reviewer_account: reviewer.account)
    request.reload
    [request, result.group_account, request.initial_follow]
  end

  def follows(owner, group)
    Follow.where(account: owner, target_account: group)
  end

  # A simulated Crash is caught by the spec process, unlike a real process
  # death. Expire its persisted lease before exercising scheduler recovery.
  def expire_claim!(record)
    record.update_columns(claim_expires_at: 1.second.ago)
  end

  it 'does not create a group, an owner, or a follow while the request is pending or rejected' do
    request = submit('stillpending')

    expect(request).to be_pending
    expect(Account.where(username: 'stillpending')).to be_empty
    expect(GroupInitialFollow.count).to eq 0
    expect(Follow.count).to eq 0

    GroupCreationRequests::RejectService.call(request: request, reviewer_account: reviewer.account, decision_note: 'Not now')

    expect(request.reload).to be_rejected
    expect(GroupInitialFollow.count).to eq 0
    expect(Account.where(username: 'stillpending')).to be_empty
  end

  it 'follows once through FollowService and does not deliver ActivityPub for a local group' do
    request, group, record = approve_without_running('opened')
    expect(MergeWorker).to receive(:perform_async).with(group.id, requester.account.id).and_call_original
    expect(LocalNotificationWorker).to receive(:perform_async).with(group.id, kind_of(Integer), 'Follow', 'follow').and_call_original
    expect(ActivityPub::DeliveryWorker).not_to receive(:perform_async)

    described_class.call(record)

    expect(record.reload).to be_succeeded
    expect(record.outcome).to eq 'created_follow'
    expect(record.relationship_recorded_at).to be_present
    expect(record.follow_id).to eq follows(requester.account, group).pick(:id)
    expect(follows(requester.account, group).count).to eq 1
    expect(group.user).to be_nil
    expect(GroupRoleAssignment.active.owner.find_by!(group_account: group).member_account).to eq requester.account

    described_class.call(record.reload)
    GroupInitialFollows::Worker.new.perform(request.id)
    expect(follows(requester.account, group).count).to eq 1
  end

  it 'rolls the follow back when the process dies before the discharge timestamp commits' do
    _request, group, record = approve_without_running('crashinsert')

    expect do
      described_class.call(record, crash_after: :after_relationship_insert)
    end.to raise_error(described_class::Crash, 'after_relationship_insert')

    expect(follows(requester.account, group)).to be_empty
    expect(record.reload).to be_processing
    expect(record.relationship_recorded_at).to be_nil
    expect(record.follow_id).to be_nil

    described_class.call(record)
    expect(follows(requester.account, group).count).to eq 1
    expect(record.reload).to be_succeeded
  end

  it 'does not follow again when the owner unfollows after the follow commits and before the terminal marker' do
    _request, group, record = approve_without_running('crashmarker')

    expect do
      described_class.call(record, crash_after: :after_latch_commit)
    end.to raise_error(described_class::Crash, 'after_latch_commit')

    expect(follows(requester.account, group).count).to eq 1
    expect(record.reload).to be_processing
    expect(record).to be_discharged
    expect(record.claim_expires_at).to be > Time.current
    expect(record.outcome).to eq 'created_follow'
    expect(record.finished_at).to be_nil

    UnfollowService.new.call(requester.account, group)
    expect(follows(requester.account, group)).to be_empty

    described_class.call(record.reload)
    GroupInitialFollows::Worker.new.perform(record.group_creation_request_id)

    expect(follows(requester.account, group)).to be_empty
    expect(FollowRequest.where(account: requester.account, target_account: group)).to be_empty
    expect(record.reload).to be_succeeded
    expect(record.outcome).to eq 'created_follow'
    expect(record).to be_discharged
    expect(GroupInitialFollows::Retry.call(request: record.group_creation_request, actor_account: reviewer.account)).to eq :already_done
    expect(follows(requester.account, group)).to be_empty
  end

  it 'does not enqueue distribution when the follow savepoint rolls back' do
    _request, group, record = approve_without_running('noside')
    jobs = []
    allow(MergeWorker).to receive(:perform_async) { |*args| jobs << args }
    allow(LocalNotificationWorker).to receive(:perform_async) { |*args| jobs << args }
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async) { |*args| jobs << args }
    expect(NotifyService).not_to receive(:new)

    expect do
      described_class.call(record, crash_after: :after_relationship_insert)
    end.to raise_error(described_class::Crash, 'after_relationship_insert')

    expect(jobs).to be_empty
    expect(follows(requester.account, group)).to be_empty
    expect(File.read(Rails.root.join('app/services/group_initial_follows/perform.rb'))).not_to include('pg_advisory')
  end

  it 'distributes once after commit and does not distribute again when the owner already unfollowed' do
    _request, group, record = approve_without_running('afterjobs')
    jobs = []
    allow(MergeWorker).to receive(:perform_async) { |*args| jobs << [:merge, args] }
    allow(LocalNotificationWorker).to receive(:perform_async) { |*args| jobs << [:local, args] }

    expect do
      described_class.call(record, crash_after: :after_latch_commit)
    end.to raise_error(described_class::Crash, 'after_latch_commit')
    expect(jobs).to be_empty
    expect(follows(requester.account, group).count).to eq 1
    expect(record.reload.distribution_enqueued_at).to be_nil
    expect(record.claim_expires_at).to be > Time.current

    expire_claim!(record)
    described_class.call(record)
    expect(jobs.size).to eq 2
    expect(follows(requester.account, group).count).to eq 1
    expect(record.reload.distribution_enqueued_at).to be_present

    UnfollowService.new.call(requester.account, group)
    described_class.call(record.reload)
    expect(jobs.size).to eq 2
    expect(follows(requester.account, group)).to be_empty
  end

  it 'records the empty-home hint with the Follow and replays optional effects after a crash' do
    _request, group, record = approve_without_running('recoverextras')
    allow(Moderation::FollowGateShadowObserver).to receive(:enabled?).and_return(true)
    expect do
      described_class.call(record, crash_after: :after_latch_commit)
    end.to raise_error(described_class::Crash)

    record.reload
    expect(record.home_feed_partial_required?).to be true
    expect(record.shadow_observation_required?).to be true
    expect(record.shadow_target_locked?).to be false
    attempted_at = record.relationship_recorded_at

    expect(FollowService).to receive(:distribute_persisted!).with(
      instance_of(Follow),
      home_feed_partial_required: true,
      shadow_observation_required: true,
      shadow_target_locked: false,
      attempted_at: attempted_at
    ).and_call_original
    expect(Moderation::FollowGateShadowObserver).to receive(:observe).with(
      source_account: requester.account,
      target_account: group,
      mechanism: nil,
      target_locked: false,
      attempted_at: attempted_at
    )

    expire_claim!(record)
    described_class.call(record.reload)
    expect(record.reload).to be_succeeded
    expect(follows(requester.account, group).count).to eq 1
  end

  it 'does not mark the empty-home hint when the owner was already following someone' do
    friend = Fabricate(:account, username: 'followedbefore')
    requester.account.follow!(friend)
    _request, group, record = approve_without_running('notfirst')
    expect do
      described_class.call(record, crash_after: :after_latch_commit)
    end.to raise_error(described_class::Crash)

    expect(record.reload.home_feed_partial_required?).to be false
    expect(FollowService).to receive(:distribute_persisted!).with(
      instance_of(Follow),
      home_feed_partial_required: false,
      shadow_observation_required: false,
      shadow_target_locked: false,
      attempted_at: record.relationship_recorded_at
    ).and_call_original

    expire_claim!(record)
    described_class.call(record.reload)
    expect(record.reload).to be_succeeded
    expect(follows(requester.account, group).count).to eq 1
  end

  it 'does not invent a shadow observation when shadow mode is enabled only after the follow' do
    _request, group, record = approve_without_running('shadowlater')
    allow(Moderation::FollowGateShadowObserver).to receive(:enabled?).and_return(false)
    expect do
      described_class.call(record, crash_after: :after_latch_commit)
    end.to raise_error(described_class::Crash)

    expect(record.reload.shadow_observation_required?).to be false
    allow(Moderation::FollowGateShadowObserver).to receive(:enabled?).and_return(true)
    expect(Moderation::FollowGateShadowObserver).not_to receive(:observe)

    expire_claim!(record)
    described_class.call(record.reload)
    expect(record.reload).to be_succeeded
    expect(follows(requester.account, group).count).to eq 1
  end

  it 'does not distribute again when a follow request became a follow before resume' do
    _request, group, record = approve_without_running('accepted')
    group.update!(locked: true)
    jobs = []
    allow(MergeWorker).to receive(:perform_async) { |*args| jobs << args }

    expect do
      described_class.call(record, crash_after: :after_latch_commit)
    end.to raise_error(described_class::Crash)
    expect(requester.account.requested?(group)).to be true
    expect(jobs).to be_empty

    group.update!(locked: false)
    AuthorizeFollowService.new.call(requester.account, group)
    expect(requester.account.following?(group)).to be true
    sent = jobs.size

    described_class.call(record.reload)
    expect(jobs.size).to eq sent
    expect(follows(requester.account, group).count).to eq 1
    expect(record.reload).to be_succeeded

    UnfollowService.new.call(requester.account, group)
    described_class.call(record.reload)
    expect(follows(requester.account, group)).to be_empty
  end

  it 'does not follow after a block is removed unless an administrator retries' do
    request, group, record = approve_without_running('unblocked')
    group.block!(requester.account)
    described_class.call(record)
    expect(record.reload).to be_permanent_failure
    group.unblock!(requester.account)

    described_class.call(record.reload)
    expect(follows(requester.account, group)).to be_empty
    expect(record.reload).to be_permanent_failure

    [nil, requester.account, Fabricate(:user).account, user_with_role('Moderator').account].each do |actor|
      expect(GroupInitialFollows::Retry.call(request: request, actor_account: actor)).to eq :not_authorized
    end
    expect(follows(requester.account, group)).to be_empty
    allow(GroupInitialFollows::Worker).to receive(:perform_async).and_call_original
    expect(GroupInitialFollows::Retry.call(request: request, actor_account: reviewer.account)).to eq :enqueued
    expect(follows(requester.account, group).count).to eq 1
  end

  it 'does not put the follow back after a finished attempt is undone' do
    request, group, record = approve_without_running('undone')
    described_class.call(record)
    UnfollowService.new.call(requester.account, group)

    described_class.call(record.reload)
    GroupInitialFollows::Worker.new.perform(request.id)

    expect(follows(requester.account, group)).to be_empty
    expect(record.reload).to be_succeeded
    expect(GroupInitialFollows::Retry.call(request: request, actor_account: reviewer.account)).to eq :already_done
  end

  it 'completes an existing follow without calling FollowService' do
    _request, group, record = approve_without_running('already')
    requester.account.follow!(group)
    expect(FollowService).not_to receive(:new)

    described_class.call(record)

    expect(record.reload).to be_completed
    expect(record.outcome).to eq 'existing_follow'
    expect(follows(requester.account, group).count).to eq 1
    described_class.call(record.reload)
    expect(follows(requester.account, group).count).to eq 1
  end

  it 'keeps a locked group as a follow request and does not repeat it after cancellation' do
    request, group, record = approve_without_running('lockedgroup')
    group.update!(locked: true)

    described_class.call(record)

    expect(requester.account.following?(group)).to be false
    expect(requester.account.requested?(group)).to be true
    expect(record.reload).to be_succeeded
    expect(record.outcome).to eq 'created_follow_request'
    request_id = FollowRequest.find_by!(account: requester.account, target_account: group).id

    described_class.call(record.reload)
    expect(FollowRequest.find_by!(account: requester.account, target_account: group).id).to eq request_id

    FollowRequest.find(request_id).destroy!
    described_class.call(record.reload)
    GroupInitialFollows::Worker.new.perform(request.id)

    expect(requester.account.requested?(group)).to be false
    expect(requester.account.following?(group)).to be false
    expect(record.reload).to be_succeeded
  end

  it 'stores a permanent failure and does not follow a disabled, suspended, or blocked owner' do
    _request, group, disabled_record = approve_without_running('disabledowner')
    requester.update!(disabled: true)
    described_class.call(disabled_record)
    expect(disabled_record.reload).to be_permanent_failure
    expect(disabled_record.last_error).to eq 'owner_unavailable'
    expect(follows(requester.account, group)).to be_empty
    requester.update!(disabled: false)

    _request, suspended_group, suspended_record = approve_without_running('suspendedowner')
    requester.account.update!(suspended_at: Time.now.utc)
    described_class.call(suspended_record)
    expect(suspended_record.reload.last_error).to eq 'owner_unavailable'
    expect(follows(requester.account, suspended_group)).to be_empty
    requester.account.update!(suspended_at: nil)

    _request, blocked_group, blocked_record = approve_without_running('blockedowner')
    blocked_group.block!(requester.account)
    described_class.call(blocked_record)
    expect(blocked_record.reload).to be_permanent_failure
    expect(blocked_record.last_error).to eq 'not_permitted'
    expect(follows(requester.account, blocked_group)).to be_empty

    described_class.call(blocked_record.reload)
    expect(follows(requester.account, blocked_group)).to be_empty
  end

  it 'follows after an administrator reopens a permanent failure once the owner is usable again' do
    request, group, record = approve_without_running('reopen')
    requester.update!(disabled: true)
    described_class.call(record)
    expect(record.reload).to be_permanent_failure
    requester.update!(disabled: false)

    described_class.call(record.reload)
    expect(follows(requester.account, group)).to be_empty

    allow(GroupInitialFollows::Worker).to receive(:perform_async).and_call_original
    expect(GroupInitialFollows::Retry.call(request: request, actor_account: reviewer.account)).to eq :enqueued
    expect(follows(requester.account, group).count).to eq 1
    expect(record.reload).to be_succeeded
  end

  it 'turns a silenced owner into a follow request instead of forcing acceptance' do
    _request, group, record = approve_without_running('silencedowner')
    requester.account.update!(silenced_at: Time.now.utc)

    described_class.call(record)

    expect(requester.account.requested?(group)).to be true
    expect(requester.account.following?(group)).to be false
    expect(record.reload.outcome).to eq 'created_follow_request'
  end

  it 'stops unexpected errors after the attempt cap and keeps rate limits retryable' do
    _request, group, record = approve_without_running('capped')
    record.update_columns(attempts: GroupInitialFollow::MAX_ATTEMPTS - 1)
    allow(FollowService).to receive(:new).and_raise(RuntimeError, 'boom')

    expect { described_class.call(record) }.to raise_error(RuntimeError, 'boom')
    expect(record.reload).to be_permanent_failure
    expect(record.last_error).to eq 'attempts_exhausted'
    expect(follows(requester.account, group)).to be_empty

    _request, _group, limited = approve_without_running('limited')
    limited.update_columns(attempts: GroupInitialFollow::MAX_ATTEMPTS)
    allow(FollowService).to receive(:new).and_raise(Mastodon::RateLimitExceededError)

    expect { described_class.call(limited) }.not_to raise_error
    expect(limited.reload).to be_retryable_failure
    expect(limited.last_error).to eq 'rate_limited'
  end

  it 'announces a public mention only while the finished follow still exists' do
    _request, group, record = approve_without_running('announced')
    described_class.call(record)
    allow(DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)

    status = Fabricate(:status, account: requester.account, visibility: :public, text: "hello @#{group.username}")
    ProcessMentionsService.new.call(status)
    expect(Status.where(account: group, reblog_of_id: status.id).count).to eq 1
    expect(status.reload).not_to be_discarded

    silent = Fabricate(:status, account: requester.account, visibility: :public, text: 'quiet')
    silent.mentions.create!(account: group, silent: true)
    ProcessMentionsService.new.call(silent)
    expect(Status.where(account: group, reblog_of_id: silent.id)).to be_empty

    UnfollowService.new.call(requester.account, group)
    later = Fabricate(:status, account: requester.account, visibility: :public, text: "again @#{group.username}")
    ProcessMentionsService.new.call(later)
    expect(Status.where(account: group, reblog_of_id: later.id)).to be_empty
  end

  it 'keeps search, a bot follow, and a remote follow working for the approved group' do
    _request, group, record = approve_without_running('visiblegroup')
    described_class.call(record)

    expect(Account.searchable).to include(group)
    expect(Account.discoverable.groups).to include(group)
    expect(group.public_key).to be_present
    expect(ActivityPub::TagManager.instance.uri_for(group)).to include(group.username)

    bot = Fabricate(:user, account: Fabricate(:account, username: 'helperbot', actor_type: 'Service'))
    FollowService.new.call(bot.account, group)
    expect(bot.account.following?(group)).to be true
    expect(bot.account.requested?(group)).to be false

    remote = Fabricate(
      :account,
      username: 'visitor',
      domain: 'remote.test',
      protocol: :activitypub,
      uri: 'https://remote.test/users/visitor',
      inbox_url: 'https://remote.test/inbox'
    )
    FollowService.new.call(remote, group)
    expect(remote.following?(group)).to be true
    expect(GroupInitialFollow.where(group_creation_request: record.group_creation_request).count).to eq 1
  end

  it 'does not backfill a follow onto a group that has no obligation row' do
    legacy = Fabricate(:account, username: 'legacygroup', actor_type: 'Group', discoverable: true)
    legacy.account_stat.save!
    expect(GroupInitialFollow.count).to eq 0

    expect(GroupInitialFollows::Recovery.call).to eq 0
    expect(Follow.where(target_account: legacy)).to be_empty
    migration = File.read(Rails.root.join('db/migrate/20261113170000_create_group_initial_follows.rb'))
    expect(migration).to include('def down')
    expect(migration).to include('drop_table :group_initial_follows')
    expect(migration).not_to match(/INSERT\s+INTO/i)
    expect(migration).not_to match(/^\s*UPDATE\s+/i)
    expect(YAML.safe_load(File.read(Rails.root.join('config/settings.yml')), aliases: true).dig('defaults', 'group_creation_requests')).to be false
  end
end
