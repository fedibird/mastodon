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
    allow(Sidekiq::Queue).to receive(:new).and_return(instance_double(Sidekiq::Queue, size: 1, latency: 0.2))
    allow(Sidekiq::Stats).to receive(:new).and_return(instance_double(Sidekiq::Stats, retry_size: 0))
    allow(Sidekiq::ProcessSet).to receive(:new).and_return([{ 'concurrency' => 4, 'queues' => ['push'] }, { 'concurrency' => 3, 'queues' => ['pull'] }])

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

  describe 'dispatch/load observation' do
    it 'records load and execution-policy snapshots for a pass' do
      add_target(0)
      add_target(1)

      expect { worker.perform(batch.id) }.to change(FollowImportDispatchObservation, :count).by(1)

      observation = FollowImportDispatchObservation.last
      expect(observation.batch_id).to eq batch.id
      expect(observation.candidate_count).to eq 2
      expect(observation.claimed_count).to eq 2
      expect(observation.batch_pending_before).to eq 2
      expect(observation.batch_pending_after).to eq 0
      expect(observation.pending_count).to eq 0
      expect(observation.global_pending_count).to eq 2
      expect(observation.active_batch_count).to eq 1
      expect(observation.load_snapshot['queues']['push']).to include('size' => 1, 'latency' => 0.2)
      expect(observation.load_snapshot['push_concurrency']).to eq 4
      expect(observation.load_snapshot['pull_concurrency']).to eq 3
      expect(observation.execution_policy['execution_batch_size']).to eq FollowImport::ExecutionPolicy.execution_batch_size
      expect(observation.execution_policy['execution_reschedule_in']).to eq FollowImport::ExecutionPolicy.execution_reschedule_in.to_i
      expect(observation.execution_policy['gate_enforcement_enabled']).to eq false
      expect(observation.execution_policy['schema_version']).to eq 3
      expect(observation.execution_policy['load_snapshot_timing']).to eq 'pre_dispatch'
    end

    it 'captures LoadSnapshot before RelationshipWorker jobs are enqueued' do
      order = []
      allow(FollowImport::LoadSnapshot).to receive(:capture) do
        order << :load_snapshot
        { 'schema_version' => 2, 'queues' => {} }
      end
      allow(Import::RelationshipWorker).to receive(:perform_async) do |*_args|
        order << :enqueue
      end
      add_target(0)

      worker.perform(batch.id)

      expect(order).to eq %i(load_snapshot enqueue)
    end

    it 'records global pending and active-batch counts at pre-dispatch' do
      other = FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                                        target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
      other.targets.create!(target_key_hash: 'other-a', position: 0)
      other.targets.create!(target_key_hash: 'other-b', position: 1)
      add_target(0)
      add_target(1)

      worker.perform(batch.id)

      observation = FollowImportDispatchObservation.last
      expect(observation.batch_pending_before).to eq 2
      expect(observation.batch_pending_after).to eq 0
      expect(observation.global_pending_count).to eq 4
      expect(observation.active_batch_count).to eq 2
    end

    it 'stores NULL rather than 0 when a backlog count cannot be measured' do
      allow(FollowImport::DispatchCounts).to receive(:pending_for).and_return(nil)
      allow(FollowImport::DispatchCounts).to receive(:global_pending).and_return(nil)
      allow(FollowImport::DispatchCounts).to receive(:active_batches).and_return(nil)
      add_target(0)

      worker.perform(batch.id)

      observation = FollowImportDispatchObservation.last
      expect(observation.batch_pending_before).to be_nil
      expect(observation.batch_pending_after).to be_nil
      expect(observation.pending_count).to be_nil
      expect(observation.global_pending_count).to be_nil
      expect(observation.active_batch_count).to be_nil
    end

    it 'records an observation even when no targets are claimed' do
      expect { worker.perform(batch.id) }.to change(FollowImportDispatchObservation, :count).by(1)

      observation = FollowImportDispatchObservation.last
      expect(observation.candidate_count).to eq 0
      expect(observation.claimed_count).to eq 0
    end

    it 'records the successful enqueues when a later enqueue raises' do
      first = add_target(0)
      second = add_target(1)
      calls = 0
      allow(Import::RelationshipWorker).to receive(:perform_async) do
        calls += 1
        raise StandardError, 'redis down' if calls == 2
      end

      expect { worker.perform(batch.id) }.to raise_error(StandardError)

      observation = FollowImportDispatchObservation.last
      expect(observation.candidate_count).to eq 2
      expect(observation.claimed_count).to eq 1
      expect(observation.pass_error_class).to eq 'StandardError'
      expect(first.reload.state).to eq 'queued'
      expect(second.reload.state).to eq 'pending'
    end

    it 'does not record an observed zero candidate count when selection fails' do
      add_target(0)
      allow(worker).to receive(:select_pending_candidates).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect { worker.perform(batch.id) }.to raise_error(ActiveRecord::StatementInvalid)

      observation = FollowImportDispatchObservation.last
      expect(observation.candidate_count).to be_nil
      expect(observation.pass_error_class).to eq 'ActiveRecord::StatementInvalid'
    end

    it 'does not change claim count or reschedule timing when telemetry insert fails' do
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(1)
      allow(FollowImport::ExecutionPolicy).to receive(:execution_reschedule_in).and_return(30.seconds)
      allow(described_class).to receive(:perform_in)
      allow(FollowImportDispatchObservation).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')
      add_target(0)
      add_target(1)

      expect { worker.perform(batch.id) }.not_to raise_error

      expect(batch.targets.order(:position).map(&:reload).map(&:state)).to eq %w(queued pending)
      expect(described_class).to have_received(:perform_in).with(30.seconds, batch.id)
    end
  end
end
