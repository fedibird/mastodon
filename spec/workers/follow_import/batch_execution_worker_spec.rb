# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::BatchExecutionWorker do
  subject(:worker) { described_class.new }

  let(:account)          { Fabricate(:account) }
  let(:importer_subject) { ModerationSubject.for_account!(account) }
  let(:batch) do
    FollowImportBatch.create!(subject: importer_subject, imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  def add_target(position)
    batch.targets.create!(target_key_hash: "key-#{position}", position: position)
  end

  before do
    # Recover fixed work per claimed target (CSV parsing is covered elsewhere).
    allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for) do |_resolver, target|
      { acct: "acct-#{target.id}@remote.test", options: { 'show_reblogs' => true } }
    end
    # Default gate proposal (shadow-by-default => executes regardless).
    allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call)
      .and_return({ 'proposed_friction' => 'allow', 'policy_version' => 'v', 'params_digest' => 'd', 'subject_id' => nil })
    allow(Import::RelationshipWorker).to receive(:perform_async)
  end

  it 'claims pending targets, transitions them to queued, and enqueues their follow work' do
    t1 = add_target(0)
    t2 = add_target(1)

    worker.perform(batch.id)

    expect(t1.reload.state).to eq 'queued'
    expect(t2.reload.state).to eq 'queued'
    expect(Import::RelationshipWorker).to have_received(:perform_async)
      .with(account.id, "acct-#{t1.id}@remote.test", 'follow', hash_including('follow_import_target_id' => t1.id, 'import_batch_id' => batch.id))
    expect(Import::RelationshipWorker).to have_received(:perform_async)
      .with(account.id, "acct-#{t2.id}@remote.test", 'follow', hash_including('follow_import_target_id' => t2.id))
  end

  it 'claims at most the batch size per pass in position order, then reschedules while progress remains' do
    allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(1)
    allow(described_class).to receive(:perform_in)
    t1 = add_target(0)
    t2 = add_target(1)

    worker.perform(batch.id)

    expect(t1.reload.state).to eq 'queued'
    expect(t2.reload.state).to eq 'pending'
    expect(described_class).to have_received(:perform_in).with(anything, batch.id)
  end

  it 'does not reschedule once all targets are drained' do
    allow(described_class).to receive(:perform_in)
    add_target(0)

    worker.perform(batch.id)

    expect(described_class).not_to have_received(:perform_in)
  end

  it 'is a no-op when there are no pending targets' do
    allow(described_class).to receive(:perform_in)

    worker.perform(batch.id)

    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    expect(described_class).not_to have_received(:perform_in)
  end

  it 'does not double-claim or re-enqueue a target that is already queued' do
    t = add_target(0)
    FollowImport::TargetTransitionService.new.mark_queued(t)

    worker.perform(batch.id)

    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
  end

  describe 'shadow-by-default gate' do
    it 'executes even when the gate would propose friction, while enforcement is off' do
      allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call)
        .and_return({ 'proposed_friction' => 'delay' })
      t = add_target(0)

      worker.perform(batch.id)

      expect(t.reload.state).to eq 'queued'
      expect(Import::RelationshipWorker).to have_received(:perform_async)
    end
  end

  describe 'when enforcement is explicitly enabled' do
    before { allow(FollowImport::ExecutionPolicy).to receive(:gate_enforcement_enabled?).and_return(true) }

    it 'executes an allow proposal' do
      allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call)
        .and_return({ 'proposed_friction' => 'allow' })
      t = add_target(0)

      worker.perform(batch.id)

      expect(t.reload.state).to eq 'queued'
    end

    it 'leaves targets pending and stops rescheduling on a delay proposal (zero progress)' do
      allow(described_class).to receive(:perform_in)
      allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call)
        .and_return({ 'proposed_friction' => 'delay' })
      t = add_target(0)

      worker.perform(batch.id)

      expect(t.reload.state).to eq 'pending'
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
      expect(described_class).not_to have_received(:perform_in)
    end

    it 'leaves targets pending on a moderator_review proposal' do
      allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call)
        .and_return({ 'proposed_friction' => 'moderator_review' })
      t = add_target(0)

      worker.perform(batch.id)

      expect(t.reload.state).to eq 'pending'
    end
  end

  describe 'enqueue-failure recovery' do
    it 'releases the claim back to pending and re-raises when the enqueue fails' do
      target = add_target(0)
      allow(Import::RelationshipWorker).to receive(:perform_async).and_raise(StandardError, 'redis down')

      expect { worker.perform(batch.id) }.to raise_error(StandardError)

      target.reload
      expect(target.state).to eq 'pending'
      expect(target.queued_at).to be_nil
    end

    it 'lets a retry reclaim and enqueue a target whose earlier enqueue failed' do
      target = add_target(0)
      calls = 0
      allow(Import::RelationshipWorker).to receive(:perform_async) do
        calls += 1
        raise StandardError, 'redis down' if calls == 1
      end

      expect { worker.perform(batch.id) }.to raise_error(StandardError)
      expect(target.reload.state).to eq 'pending'

      described_class.new.perform(batch.id)

      expect(target.reload.state).to eq 'queued'
      expect(Import::RelationshipWorker).to have_received(:perform_async).twice
    end
  end

  it 'is a no-op for an unknown batch' do
    expect { worker.perform(-1) }.not_to raise_error
  end
end
