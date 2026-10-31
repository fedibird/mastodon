# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Group creation decision races' do
  self.use_transactional_tests = false

  before do
    load Rails.root.join('db', 'seeds', '03_roles.rb')
    Setting.group_creation_requests = true
    ActiveRecord::Base.connection_pool.lock_thread = false
  end

  after do
    Setting.group_creation_requests = false
    GroupCreationDecision.delete_all
    GroupRegistrationInvitePolicy.delete_all
    GroupRoleAssignment.delete_all
    ManagedGroup.delete_all
    GroupCreationRequest.delete_all
    ActiveRecord::Base.connection_pool.lock_thread = true
  end

  def submit(username:, requester: Fabricate(:user))
    GroupCreationRequest.create!(
      requester_account: requester.account,
      username: username,
      display_name: username,
      note: 'race'
    )
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

  it 'lets one of two reviewers approve' do
    request = submit(username: "race#{SecureRandom.hex(4)}")
    other = user_with_role('Admin')
    outcomes = race(
      -> { GroupCreationRequests::ApproveService.call(request: GroupCreationRequest.find(request.id), reviewer_account: user_with_role('Owner').account) },
      -> { GroupCreationRequests::ApproveService.call(request: GroupCreationRequest.find(request.id), reviewer_account: other.account) }
    )

    codes = outcomes.map { |item| item.respond_to?(:code) ? item.code : item.class.name }
    expect(codes).to contain_exactly(:approved, :not_pending)
    expect(request.reload).to be_approved
    expect(Account.where(username: request.username).count).to eq 1
    expect(GroupRoleAssignment.active.owner.count).to eq 1
    expect(GroupCreationDecision.count).to eq 1
  end

  it 'lets approval and cancellation produce one terminal state' do
    request = submit(username: "cancel#{SecureRandom.hex(4)}")
    reviewer = user_with_role('Owner')
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
      expect(GroupCreationDecision.count).to eq 0
    end
  end

  it 'keeps the losing same-name request pending' do
    left = submit(username: 'sharedname')
    right = submit(username: 'sharedname')
    reviewer = user_with_role('Owner')
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
