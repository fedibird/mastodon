# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Group creation decision races' do
  self.use_transactional_tests = false

  before do
    load Rails.root.join('db', 'seeds', '03_roles.rb')
    Setting.group_creation_requests = true
    ActiveRecord::Base.connection_pool.lock_thread = false
    @created_request_ids = []
    @created_user_ids = []
  end

  after do
    cleanup_created_records!
    Setting.group_creation_requests = false
    ActiveRecord::Base.connection_pool.lock_thread = true
  end

  def track_user(user)
    @created_user_ids << user.id
    user
  end

  def submit(username:, requester: track_user(Fabricate(:user)))
    request = GroupCreationRequest.create!(
      requester_account: requester.account,
      username: username,
      display_name: username,
      note: 'race'
    )
    @created_request_ids << request.id
    request
  end

  def race(*calls)
    start = Queue.new
    results = Queue.new
    threads = calls.map do |callable|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          results << callable.call
        rescue StandardError => e
          results << e
        end
      end
    end
    calls.size.times { start << true }
    threads.each { |thread| thread.join(15) }
    expect(threads.all?(&:stop?)).to be true
    Array.new(calls.size) { results.pop }
  end

  def cleanup_created_records!
    request_ids = @created_request_ids
    return if request_ids.blank?

    group_ids = GroupCreationRequest.where(id: request_ids).where.not(group_account_id: nil).pluck(:group_account_id)
    GroupCreationDecision.where(group_creation_request_id: request_ids).delete_all
    GroupRegistrationInvitePolicy.where(group_account_id: group_ids).delete_all
    GroupRoleAssignment.where(group_account_id: group_ids).delete_all
    ManagedGroup.where(account_id: group_ids).delete_all
    GroupCreationRequest.where(id: request_ids).delete_all
    AccountStat.where(account_id: group_ids).delete_all
    Account.where(id: group_ids).delete_all

    user_ids = @created_user_ids
    account_ids = User.where(id: user_ids).pluck(:account_id)
    User.where(id: user_ids).delete_all
    AccountStat.where(account_id: account_ids).delete_all
    Account.where(id: account_ids).delete_all
  end

  it 'lets one of two reviewers approve' do
    request = submit(username: "race#{SecureRandom.hex(4)}")
    owner = track_user(user_with_role('Owner'))
    other = track_user(user_with_role('Admin'))
    outcomes = race(
      -> { GroupCreationRequests::ApproveService.call(request: GroupCreationRequest.find(request.id), reviewer_account: owner.account) },
      -> { GroupCreationRequests::ApproveService.call(request: GroupCreationRequest.find(request.id), reviewer_account: other.account) }
    )

    codes = outcomes.map { |item| item.respond_to?(:code) ? item.code : item.class.name }
    expect(codes).to contain_exactly(:approved, :not_pending)
    expect(request.reload).to be_approved
    expect(Account.where(username: request.username).count).to eq 1
    expect(GroupRoleAssignment.active.owner.where(group_account_id: request.group_account_id).count).to eq 1
    expect(GroupCreationDecision.where(group_creation_request_id: request.id).count).to eq 1
  end

  it 'lets approval and cancellation produce one terminal state' do
    request = submit(username: "cancel#{SecureRandom.hex(4)}")
    reviewer = track_user(user_with_role('Owner'))
    outcomes = race(
      -> { GroupCreationRequests::ApproveService.call(request: GroupCreationRequest.find(request.id), reviewer_account: reviewer.account) },
      -> { GroupCreationRequest.find(request.id).record_cancellation! }
    )

    request.reload
    expect(request.pending?).to be false
    if request.approved?
      expect(Account.where(username: request.username).count).to eq 1
      expect(outcomes.map { |item| item.is_a?(GroupCreationRequests::DecisionResult) ? item.code : :cancelled }).to include(:approved)
    else
      expect(request).to be_cancelled
      expect(Account.where(username: request.username)).to be_empty
      expect(GroupCreationDecision.where(group_creation_request_id: request.id).count).to eq 0
    end
  end

  it 'keeps the losing same-name request pending' do
    left = submit(username: 'sharedname')
    right = submit(username: 'sharedname')
    reviewer = track_user(user_with_role('Owner'))
    outcomes = race(
      -> { GroupCreationRequests::ApproveService.call(request: GroupCreationRequest.find(left.id), reviewer_account: reviewer.account) },
      -> { GroupCreationRequests::ApproveService.call(request: GroupCreationRequest.find(right.id), reviewer_account: reviewer.account) }
    )

    codes = outcomes.map(&:code)
    expect(codes).to contain_exactly(:approved, :username_taken)
    expect(Account.where(username: 'sharedname').count).to eq 1
    expect([left.reload, right.reload].map(&:state)).to contain_exactly('approved', 'pending')
  end
end
