# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduler::FollowImportCompletionScheduler do
  subject(:worker) { described_class.new }

  let(:account) { Fabricate(:account) }
  let(:user)    { Fabricate(:user, account: account) }

  def batch_for(subject_account, imported_at: Time.now.utc)
    FollowImportBatch.create!(subject: ModerationSubject.for_account!(subject_account), import_id: nil,
                              imported_at: imported_at, mode: :merge, target_count: 0,
                              resolved_target_count: 0, unresolved_target_count: 0)
  end

  def add_target(batch, state, position)
    batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: position, state: state)
  end

  before do
    user # ensure the account has a user to email
    allow(UserMailer).to receive(:follow_import_finished).and_return(instance_double(ActionMailer::MessageDelivery, deliver_later: nil))
  end

  it 'emails the importer and marks a completed batch as notified' do
    batch = batch_for(account)
    add_target(batch, :accepted, 0)
    add_target(batch, :rejected, 1)

    worker.perform

    expect(UserMailer).to have_received(:follow_import_finished).with(user, batch, hash_including('total' => 2, 'processed' => 2, 'failed' => 1))
    expect(batch.reload.completion_notified?).to be true
    expect(batch.completion_recorded?).to be true
  end

  it 'does not treat a follow import with no batch as completed' do
    Import.create!(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt'))

    worker.perform

    expect(UserMailer).not_to have_received(:follow_import_finished)
  end

  it 'does not notify a batch that is still in progress' do
    batch = batch_for(account)
    add_target(batch, :accepted, 0)
    add_target(batch, :awaiting_response, 1)

    worker.perform

    expect(UserMailer).not_to have_received(:follow_import_finished)
    expect(batch.reload.completion_notified?).to be false
  end

  it 'does not notify a batch that was already notified' do
    batch = batch_for(account)
    add_target(batch, :accepted, 0)
    batch.mark_completion_notified!

    worker.perform

    expect(UserMailer).not_to have_received(:follow_import_finished)
  end

  it 'notifies a batch that finishes more than 30 days after imported_at' do
    batch = batch_for(account, imported_at: 45.days.ago)
    add_target(batch, :accepted, 0)

    worker.perform

    expect(UserMailer).to have_received(:follow_import_finished)
    expect(batch.reload.completion_notified?).to be true
  end

  it 'does not notify an old import that is still waiting on a deferred target' do
    batch = batch_for(account, imported_at: 45.days.ago)
    add_target(batch, :accepted, 0)
    add_target(batch, :pending, 1)

    worker.perform

    expect(UserMailer).not_to have_received(:follow_import_finished)
    expect(batch.reload.completion_notified?).to be false
  end

  it 'notifies a late-finishing batch whose completion was persisted after the lookback' do
    batch = batch_for(account, imported_at: 90.days.ago)
    target = add_target(batch, :accepted, 0)
    target.update_columns(completed_at: 45.days.ago, updated_at: 45.days.ago)
    batch.record_completion!(45.days.ago)

    worker.perform

    expect(UserMailer).to have_received(:follow_import_finished)
    expect(batch.reload.completion_notified?).to be true
  end

  it 'marks a completed batch notified even when the importer account is gone (no email)' do
    orphan = batch_for(account)
    add_target(orphan, :accepted, 0)
    orphan.subject.update!(account_id: nil)

    worker.perform

    expect(UserMailer).not_to have_received(:follow_import_finished)
    expect(orphan.reload.completion_notified?).to be true
  end
end
