# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Group initial follow concurrency' do
  self.use_transactional_tests = false

  before do
    load Rails.root.join('db', 'seeds', '03_roles.rb')
    Setting.group_creation_requests = true
    ActiveRecord::Base.connection_pool.lock_thread = false
    @created_request_ids = []
    @created_user_ids = []
  end

  after do
    cleanup!
    Setting.group_creation_requests = false
    ActiveRecord::Base.connection_pool.lock_thread = true
  end

  def track_user(user)
    @created_user_ids << user.id
    user
  end

  it 'lets two workers create only one follow' do
    requester = track_user(Fabricate(:user))
    reviewer = track_user(user_with_role('Owner'))
    request = GroupCreationRequest.create!(
      requester_account: requester.account,
      username: "both#{SecureRandom.hex(4)}",
      display_name: 'Both',
      note: 'race'
    )
    @created_request_ids << request.id
    allow(GroupInitialFollows::Worker).to receive(:perform_async)
    GroupCreationRequests::ApproveService.call(request: request, reviewer_account: reviewer.account)
    record_id = request.reload.initial_follow.id

    start = Queue.new
    done = Queue.new
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          GroupInitialFollows::Perform.call(GroupInitialFollow.find(record_id))
          done << true
        rescue StandardError => e
          done << e
        end
      end
    end
    2.times { start << true }
    threads.each { |thread| thread.join(15) }

    results = Array.new(2) { done.pop }
    expect(results).to all(be true)
    expect(Follow.where(account: requester.account, target_account: request.reload.group_account).count).to eq 1
    expect(GroupInitialFollow.find(record_id).state).to eq('succeeded').or eq('completed')
  end

  it 'does not let an expired lease create a second follow while the first worker is still running' do
    requester = track_user(Fabricate(:user))
    reviewer = track_user(user_with_role('Owner'))
    request = GroupCreationRequest.create!(
      requester_account: requester.account,
      username: "lease#{SecureRandom.hex(4)}",
      display_name: 'Lease',
      note: 'race'
    )
    @created_request_ids << request.id
    allow(GroupInitialFollows::Worker).to receive(:perform_async)
    GroupCreationRequests::ApproveService.call(request: request, reviewer_account: reviewer.account)
    record_id = request.reload.initial_follow.id

    started = Queue.new
    release = Queue.new
    outcome = Queue.new
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        GroupInitialFollows::Perform.call(GroupInitialFollow.find(record_id), after_claim: lambda {
          started << true
          release.pop
        })
        outcome << :ok
      rescue StandardError => e
        outcome << e
      end
    end

    started.pop
    GroupInitialFollow.find(record_id).update_columns(claim_expires_at: 1.minute.ago)
    GroupInitialFollows::Perform.call(GroupInitialFollow.find(record_id))
    expect(Follow.where(account: requester.account, target_account: request.reload.group_account).count).to eq 1

    release << true
    worker.join(15)
    expect(outcome.pop).to eq :ok
    expect(Follow.where(account: requester.account, target_account: request.reload.group_account).count).to eq 1
    expect(GroupInitialFollow.find(record_id)).to be_succeeded
  end

  it 'does not let a stale worker expire or fail the lease a newer worker holds' do
    request = prepare_request('stale')
    record_id = request.initial_follow.id
    a_ready = Queue.new
    a_go = Queue.new
    b_ready = Queue.new
    b_go = Queue.new
    a_result = Queue.new
    b_result = Queue.new

    stale = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        GroupInitialFollows::Perform.call(GroupInitialFollow.find(record_id), after_claim: lambda {
          a_ready << true
          a_go.pop
          raise GroupInitialFollows::Perform::Crash, 'stale'
        })
        a_result << :unexpected
      rescue GroupInitialFollows::Perform::Crash
        a_result << :crashed
      rescue StandardError => e
        a_result << e
      end
    end

    a_ready.pop
    GroupInitialFollow.find(record_id).update_columns(claim_expires_at: 1.minute.ago)

    newer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        GroupInitialFollows::Perform.call(GroupInitialFollow.find(record_id), after_claim: lambda {
          row = GroupInitialFollow.find(record_id)
          b_ready << [row.claim_token, row.claim_expires_at]
          b_go.pop
        })
        b_result << :ok
      rescue StandardError => e
        b_result << e
      end
    end

    token, expiry = b_ready.pop
    a_go << true
    expect(a_result.pop).to eq :crashed
    held = GroupInitialFollow.find(record_id)
    expect(held.claim_token).to eq token
    expect(held.claim_expires_at.to_i).to eq expiry.to_i
    expect(held).to be_processing
    expect(held.last_error).to be_nil
    expect(Follow.where(target_account_id: request.group_account_id).count).to eq 0

    b_go << true
    newer.join(15)
    stale.join(15)
    expect(b_result.pop).to eq :ok
    expect(Follow.where(account_id: request.requester_account_id, target_account_id: request.group_account_id).count).to eq 1
  end

  it 'does not let a stale failure overwrite the newer worker state' do
    request = prepare_request('stalefail')
    record_id = request.initial_follow.id
    a_ready = Queue.new
    a_go = Queue.new
    b_ready = Queue.new
    b_go = Queue.new

    stale = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        GroupInitialFollows::Perform.call(GroupInitialFollow.find(record_id), after_claim: lambda {
          a_ready << true
          a_go.pop
          raise Mastodon::NotPermittedError
        })
      rescue Mastodon::NotPermittedError
        nil
      end
    end

    a_ready.pop
    GroupInitialFollow.find(record_id).update_columns(claim_expires_at: 1.minute.ago)
    newer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        GroupInitialFollows::Perform.call(GroupInitialFollow.find(record_id), after_claim: lambda {
          row = GroupInitialFollow.find(record_id)
          b_ready << row.claim_token
          b_go.pop
        })
      end
    end

    token = b_ready.pop
    a_go << true
    stale.join(15)
    held = GroupInitialFollow.find(record_id)
    expect(held.claim_token).to eq token
    expect(held).to be_processing
    expect(held).not_to be_permanent_failure
    expect(held.last_error).to be_nil

    b_go << true
    newer.join(15)
    expect(Follow.where(target_account_id: request.group_account_id).count).to eq 1
  end

  it 'lets only one worker distribute a committed follow' do
    request = prepare_request('oncedeliver')
    record_id = request.initial_follow.id
    expect do
      GroupInitialFollows::Perform.call(GroupInitialFollow.find(record_id), crash_after: :after_latch_commit)
    end.to raise_error(GroupInitialFollows::Perform::Crash)
    GroupInitialFollow.find(record_id).update_columns(claim_expires_at: 1.second.ago)

    calls = 0
    entered = Queue.new
    release = Queue.new
    mutex = Mutex.new
    allow(FollowService).to receive(:distribute_persisted!).and_wrap_original do |method, record, **options|
      mine = mutex.synchronize { calls += 1 }
      if mine == 1
        entered << true
        release.pop
      end
      method.call(record, **options)
    end

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        GroupInitialFollows::Perform.call(GroupInitialFollow.find(record_id))
      end
    end
    entered.pop
    GroupInitialFollows::Perform.call(GroupInitialFollow.find(record_id))
    expect(calls).to eq 1
    release << true
    first.join(15)
    expect(calls).to eq 1
    expect(Follow.where(target_account_id: request.group_account_id).count).to eq 1
    expect(GroupInitialFollow.find(record_id).distribution_enqueued_at).to be_present
  end

  def prepare_request(prefix)
    requester = track_user(Fabricate(:user))
    reviewer = track_user(user_with_role('Owner'))
    request = GroupCreationRequest.create!(
      requester_account: requester.account,
      username: "#{prefix}#{SecureRandom.hex(3)}",
      display_name: prefix,
      note: 'race'
    )
    @created_request_ids << request.id
    allow(GroupInitialFollows::Worker).to receive(:perform_async)
    GroupCreationRequests::ApproveService.call(request: request, reviewer_account: reviewer.account)
    request.reload
  end

  def cleanup!
    request_ids = @created_request_ids
    return if request_ids.blank?

    group_ids = GroupCreationRequest.where(id: request_ids).where.not(group_account_id: nil).pluck(:group_account_id)
    owner_ids = GroupCreationRequest.where(id: request_ids).pluck(:requester_account_id)
    Follow.where(target_account_id: group_ids).delete_all
    FollowRequest.where(target_account_id: group_ids).delete_all
    GroupInitialFollow.where(group_creation_request_id: request_ids).delete_all
    GroupCreationDecision.where(group_creation_request_id: request_ids).delete_all
    GroupRegistrationInvitePolicy.where(group_account_id: group_ids).delete_all
    GroupRoleAssignment.where(group_account_id: group_ids).delete_all
    ManagedGroup.where(account_id: group_ids).delete_all
    GroupCreationRequest.where(id: request_ids).delete_all
    AccountStat.where(account_id: group_ids).delete_all
    Account.where(id: group_ids).delete_all

    user_ids = @created_user_ids
    account_ids = User.where(id: user_ids).pluck(:account_id)
    Notification.where(account_id: owner_ids).delete_all
    User.where(id: user_ids).delete_all
    AccountStat.where(account_id: account_ids).delete_all
    Account.where(id: account_ids).delete_all
  end
end
