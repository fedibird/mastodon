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
    ActiveRecord::Base.connection.select_value('SELECT pg_advisory_unlock_all()')
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
