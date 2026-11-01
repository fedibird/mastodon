# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupInitialFollows::Recovery do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  around do |example|
    previous = Setting.group_creation_requests
    Setting.group_creation_requests = true
    example.run
  ensure
    Setting.group_creation_requests = previous
  end

  it 'is scheduled every five minutes and finishes a missed enqueue without following older groups' do
    schedule = File.read(Rails.root.join('config/sidekiq.yml'))
    expect(schedule).to match(/group_initial_follows_scheduler:\n\s+every: '5m'\n\s+class: Scheduler::GroupInitialFollowsScheduler\n\s+queue: scheduler/)

    requester = Fabricate(:user)
    reviewer = user_with_role('Owner')
    request = GroupCreationRequest.create!(
      requester_account: requester.account,
      username: 'recoverme',
      display_name: 'Recover',
      note: 'queued late'
    )
    allow(GroupInitialFollows::Worker).to receive(:perform_async).and_raise(RuntimeError, 'redis down')
    GroupCreationRequests::ApproveService.call(request: request, reviewer_account: reviewer.account)
    record = request.reload.initial_follow
    expect(record).to be_pending
    expect(record.last_error).to eq 'enqueue_failed'
    expect(Follow.where(account: requester.account, target_account: request.group_account)).to be_empty

    legacy = Fabricate(:account, username: 'oldgroup', actor_type: 'Group')
    record.update_columns(updated_at: 1.minute.ago)
    allow(GroupInitialFollows::Worker).to receive(:perform_async).and_call_original

    expect(Scheduler::GroupInitialFollowsScheduler.new.perform).to eq 1
    expect(Follow.where(account: requester.account, target_account: request.group_account).count).to eq 1
    expect(record.reload).to be_succeeded
    expect(Follow.where(target_account: legacy)).to be_empty
  end

  it 'finalizes a discharged row that is still processing after the claim lease' do
    requester = Fabricate(:user)
    reviewer = user_with_role('Owner')
    request = GroupCreationRequest.create!(
      requester_account: requester.account,
      username: 'leasegroup',
      display_name: 'Lease',
      note: 'half done'
    )
    allow(GroupInitialFollows::Worker).to receive(:perform_async)
    GroupCreationRequests::ApproveService.call(request: request, reviewer_account: reviewer.account)
    record = request.reload.initial_follow
    expect do
      GroupInitialFollows::Perform.call(record, crash_after: :after_latch_commit)
    end.to raise_error(GroupInitialFollows::Perform::Crash)

    record.update_columns(claim_expires_at: 1.minute.ago, updated_at: 1.minute.ago)
    allow(GroupInitialFollows::Worker).to receive(:perform_async).and_call_original

    expect(described_class.call).to eq 1
    expect(record.reload).to be_succeeded
    expect(Follow.where(account: requester.account, target_account: request.group_account).count).to eq 1
  end
end
