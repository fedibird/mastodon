# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduler::FollowImportResponseTimeoutScheduler do
  subject(:worker) { described_class.new }

  let(:batch) do
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  let(:transitions) { FollowImport::TargetTransitionService.new }

  def awaiting_response(uri:, deadline:)
    target = batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 0)
    transitions.mark_queued(target, follow_request_uri: uri)
    transitions.mark_awaiting_response(target, follow_request_uri: uri, response_deadline_at: deadline)
    target
  end

  it 'completes targets whose response deadline has elapsed' do
    overdue = awaiting_response(uri: 'https://local.test/overdue', deadline: 1.hour.ago)

    worker.perform

    target = overdue.reload
    expect(target.state).to eq 'completed_no_response'
    expect(target.completed_at).to be_present
  end

  it 'leaves targets whose deadline is still in the future' do
    pending_target = awaiting_response(uri: 'https://local.test/future', deadline: 1.hour.from_now)

    worker.perform

    expect(pending_target.reload.state).to eq 'awaiting_response'
  end

  it 'does not touch targets that already reached a terminal state' do
    accepted = awaiting_response(uri: 'https://local.test/accepted', deadline: 1.hour.ago)
    transitions.mark_accepted(accepted)

    worker.perform

    expect(accepted.reload.state).to eq 'accepted'
  end
end
