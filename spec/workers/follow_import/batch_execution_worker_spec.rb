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

  it 'refuses a scheduler-owned batch before any load, claim, or enqueue work' do
    import_record = Import.create!(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt'),
                                   follow_import_pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION)
    batch.update!(dispatch_owner: :scheduler, import_id: import_record.id)
    target = add_target(0)
    allow(described_class).to receive(:perform_in)
    allow(FollowImport::LoadSnapshot).to receive(:capture)
    allow(FollowImport::LocalLoadEnforcement).to receive(:evaluate)
    allow(FollowImport::DispatchObserver).to receive(:record)
    allow(FollowImport::ExecutionGate).to receive(:for_account)
    allow(FollowImport::ImportUnitResolver).to receive(:new)
    allow(FollowImport::TargetTransitionService).to receive(:new)

    worker.perform(batch.id)

    expect(target.reload.state).to eq 'pending'
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    expect(described_class).not_to have_received(:perform_in)
    expect(FollowImport::LoadSnapshot).not_to have_received(:capture)
    expect(FollowImport::LocalLoadEnforcement).not_to have_received(:evaluate)
    expect(FollowImport::DispatchObserver).not_to have_received(:record)
    expect(FollowImport::ExecutionGate).not_to have_received(:for_account)
    expect(FollowImport::ImportUnitResolver).not_to have_received(:new)
    expect(FollowImport::TargetTransitionService).not_to have_received(:new)
    expect(Import.exists?(import_record.id)).to be true
    expect(FollowImportBatch.exists?(batch.id)).to be true
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
      expect(observation.execution_policy['schema_version']).to eq 4
      expect(observation.execution_policy['load_snapshot_timing']).to eq 'pre_dispatch'
      expect(observation.local_load_enforcement_enabled).to eq false
      expect(observation.local_load_state).to be_nil
      expect(observation.effective_execution_budget).to be_nil
      expect(observation.load_deferred).to eq false
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

  describe 'local-load enforcement' do
    def v2_profile(overrides = {})
      {
        'version' => 2,
        'levels' => {
          'busy' => { 'budget_percent' => 40, 'push' => { 'latency' => 2 } },
          'overloaded' => { 'budget_percent' => 0, 'push' => { 'latency' => 20 } },
        },
        'fallback' => { 'budget_percent' => 20 },
      }.merge(overrides)
    end

    def enable_enforcement(injected)
      allow(FollowImport::ExecutionPolicy).to receive(:local_load_enforcement_enabled?).and_return(true)
      allow(FollowImport::LocalLoadProfile).to receive(:from_env).and_return(injected)
    end

    def attach_import
      import = Import.create!(
        account: account,
        type: 'following',
        data: attachment_fixture('new-following-imports.txt'),
        follow_import_pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION
      )
      batch.update!(import_id: import.id)
      import
    end

    it 'ignores a LocalLoadGuard recommendation while the flag is off' do
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(FollowImport::LocalLoadGuard).to receive(:evaluate).and_return(
        FollowImport::LocalLoadDecision.new(state: 'overloaded', recommended_budget: 0, would_skip: true, measurement_complete: true)
      )
      allow(described_class).to receive(:perform_in)
      3.times { |position| add_target(position) }

      worker.perform(batch.id)

      expect(FollowImport::LocalLoadGuard).not_to have_received(:evaluate)
      expect(batch.targets.where(state: :queued).count).to eq 3
      expect(described_class).not_to have_received(:perform_in)
    end

    it 'keeps the legacy candidate limit, gate stop, and finalization when the flag is off' do
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(1)
      allow(FollowImport::ExecutionPolicy).to receive(:gate_enforcement_enabled?).and_return(true)
      allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call)
        .and_return({ 'proposed_friction' => 'delay' })
      allow(described_class).to receive(:perform_in)
      add_target(0)
      add_target(1)

      worker.perform(batch.id)

      expect(batch.targets.reload.map(&:state).uniq).to eq %w(pending)
      expect(described_class).not_to have_received(:perform_in)
    end

    it 'executes normally when a healthy v2 profile recommends the full base budget' do
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(described_class).to receive(:perform_in)
      2.times { |position| add_target(position) }

      worker.perform(batch.id)

      expect(batch.targets.where(state: :queued).count).to eq 2
      expect(described_class).not_to have_received(:perform_in)
      observation = FollowImportDispatchObservation.last
      expect(observation.effective_execution_budget).to eq 10
      expect(observation.local_load_state).to eq 'normal'
      expect(observation.load_deferred).to eq false
    end

    it 'selects at most the recommended budget and reschedules on forward progress' do
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
        'queues' => { 'push' => { 'size' => 0, 'latency' => 3.0 } },
        'retry_size' => 0,
        'push_concurrency' => 4,
        'pull_concurrency' => 2
      )
      allow(described_class).to receive(:perform_in)
      10.times { |position| add_target(position) }

      worker.perform(batch.id)

      expect(batch.targets.where(state: :queued).count).to eq 4
      expect(batch.targets.where(state: :pending).count).to eq 6
      expect(Import::RelationshipWorker).to have_received(:perform_async).exactly(4).times
      expect(described_class).to have_received(:perform_in).once
      observation = FollowImportDispatchObservation.last
      expect(observation.candidate_count).to eq 4
      expect(observation.claimed_count).to eq 4
      expect(observation.effective_execution_budget).to eq 4
      expect(observation.local_load_recommended_budget).to eq 4
      expect(observation.load_deferred).to eq false
    end

    it 'defers the pass for local load: no select/gate/claim, retain Import, one recheck' do
      import = attach_import
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
        'queues' => { 'push' => { 'size' => 0, 'latency' => 25.0 } },
        'retry_size' => 0
      )
      allow(FollowImport::ExecutionGate).to receive(:for_account).and_call_original
      allow(FollowImport::ImportUnitResolver).to receive(:new).and_call_original
      allow(worker).to receive(:select_pending_candidates).and_call_original
      allow(described_class).to receive(:perform_in)
      target = add_target(0)

      worker.perform(batch.id)

      expect(worker).not_to have_received(:select_pending_candidates)
      expect(FollowImport::ExecutionGate).not_to have_received(:for_account)
      expect(FollowImport::ImportUnitResolver).not_to have_received(:new)
      expect(target.reload.state).to eq 'pending'
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
      expect(Import.exists?(import.id)).to be true
      expect(described_class).to have_received(:perform_in).once.with(
        FollowImport::ExecutionPolicy.execution_reschedule_in, batch.id
      )
      observation = FollowImportDispatchObservation.last
      expect(observation.candidate_count).to be_nil
      expect(observation.claimed_count).to eq 0
      expect(observation.effective_execution_budget).to eq 0
      expect(observation.load_deferred).to eq true
      expect(observation.local_load_state).to eq 'overloaded'
    end

    it 'recovers when a later pass sees a healthy snapshot' do
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(described_class).to receive(:perform_in)
      snapshots = [
        { 'queues' => { 'push' => { 'size' => 0, 'latency' => 25.0 } }, 'retry_size' => 0 },
        { 'queues' => { 'push' => { 'size' => 0, 'latency' => 0.1 } }, 'retry_size' => 0, 'push_concurrency' => 4, 'pull_concurrency' => 2 },
      ]
      allow(FollowImport::LoadSnapshot).to receive(:capture) { snapshots.shift }
      target = add_target(0)

      worker.perform(batch.id)
      expect(target.reload.state).to eq 'pending'
      expect(described_class).to have_received(:perform_in).once
      expect(FollowImportDispatchObservation.last.load_deferred).to eq true

      described_class.new.perform(batch.id)

      expect(target.reload.state).to eq 'queued'
      expect(Import::RelationshipWorker).to have_received(:perform_async).once
      expect(FollowImportDispatchObservation.last.load_deferred).to eq false
    end

    it 'does not start a load-recheck loop when the gate blocks a positive load budget' do
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(FollowImport::ExecutionPolicy).to receive(:gate_enforcement_enabled?).and_return(true)
      allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call)
        .and_return({ 'proposed_friction' => 'delay' })
      allow(described_class).to receive(:perform_in)
      add_target(0)

      worker.perform(batch.id)

      expect(batch.targets.reload.map(&:state)).to eq %w(pending)
      expect(described_class).not_to have_received(:perform_in)
      observation = FollowImportDispatchObservation.last
      expect(observation.claimed_count).to eq 0
      expect(observation.load_deferred).to eq false
      expect(observation.effective_execution_budget).to eq 10
    end

    it 'does not classify unrecoverable work as load deferral' do
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for).and_return(nil)
      allow(described_class).to receive(:perform_in)
      add_target(0)

      worker.perform(batch.id)

      expect(described_class).not_to have_received(:perform_in)
      expect(FollowImportDispatchObservation.last.load_deferred).to eq false
    end

    it 'finalizes and does not load-recheck when nothing is pending, even if load is overloaded' do
      import = attach_import
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
        'queues' => { 'push' => { 'size' => 0, 'latency' => 25.0 } },
        'retry_size' => 0
      )
      allow(described_class).to receive(:perform_in)

      worker.perform(batch.id)

      expect(described_class).not_to have_received(:perform_in)
      expect(Import.exists?(import.id)).to be false
      expect(FollowImportDispatchObservation.last.load_deferred).to eq false
    end

    it 'uses the configured fallback when the runtime snapshot is incomplete' do
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
        'queues' => { 'push' => { 'error_class' => 'RuntimeError' } }
      )
      allow(described_class).to receive(:perform_in)
      5.times { |position| add_target(position) }

      worker.perform(batch.id)

      expect(batch.targets.where(state: :queued).count).to eq 2
      observation = FollowImportDispatchObservation.last
      expect(observation.local_load_state).to eq 'unknown'
      expect(observation.local_load_fallback_used).to eq true
      expect(observation.effective_execution_budget).to eq 2
      expect(observation.load_deferred).to eq false
    end

    it 'survives LocalLoadGuard.evaluate raising at the boundary and applies the v2 fallback' do
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(FollowImport::Telemetry).to receive(:warn_failure)
      allow(FollowImport::LocalLoadGuard).to receive(:evaluate).and_raise(RuntimeError, 'boom')
      add_target(0)
      add_target(1)

      expect { worker.perform(batch.id) }.not_to raise_error

      expect(batch.targets.where(state: :queued).count).to eq 2
      expect(FollowImport::Telemetry).to have_received(:warn_failure).with('local_load_budget', instance_of(RuntimeError))
      observation = FollowImportDispatchObservation.last
      expect(observation.local_load_state).to eq 'evaluation_error'
      expect(observation.local_load_state).not_to eq 'invalid'
      expect(observation.local_load_fallback_used).to eq true
      expect(observation.effective_execution_budget).to eq 2
      expect(observation.pass_error_class).to be_nil
    end

    it 'warns and uses fallback when the controller raises, without failing the pass' do
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(FollowImport::Telemetry).to receive(:warn_failure)
      allow_any_instance_of(FollowImport::LocalLoadGuard).to receive(:missing_measurements)
        .and_raise(RuntimeError, 'internal boom')
      add_target(0)

      expect { worker.perform(batch.id) }.not_to raise_error

      expect(FollowImportTarget.find_by(batch: batch).state).to eq 'queued'
      expect(FollowImport::Telemetry).to have_received(:warn_failure).with('local_load_guard', instance_of(RuntimeError))
      observation = FollowImportDispatchObservation.last
      expect(observation.local_load_state).to eq 'evaluation_error'
      expect(observation.local_load_fallback_used).to eq true
      expect(observation.effective_execution_budget).to eq 2
    end

    it 'preserves legacy execution and warns when the flag is on without an enforceable profile' do
      allow(FollowImport::Telemetry).to receive(:warn_failure)
      enable_enforcement(FollowImport::LocalLoadProfile.parse('{nope'))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(described_class).to receive(:perform_in)
      3.times { |position| add_target(position) }

      worker.perform(batch.id)

      expect(batch.targets.where(state: :queued).count).to eq 3
      expect(described_class).not_to have_received(:perform_in)
      expect(FollowImport::Telemetry).to have_received(:warn_failure)
        .with('local_load_enforcement', instance_of(FollowImport::LocalLoadEnforcement::NotConfigured))
      observation = FollowImportDispatchObservation.last
      expect(observation.local_load_state).to eq 'invalid'
      expect(observation.local_load_state).not_to eq 'normal'
      expect(observation.effective_execution_budget).to eq 10
      expect(observation.execution_policy['local_load_enforcement_configured']).to eq false
    end

    it 'may defer when observed concurrency is genuinely 0' do
      enable_enforcement(FollowImport::LocalLoadProfile.parse(
                           v2_profile.merge('capacity' => { 'per_push_thread' => 2 })
                         ))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
        'queues' => { 'push' => { 'size' => 0, 'latency' => 0.1 } },
        'retry_size' => 0,
        'push_concurrency' => 0,
        'pull_concurrency' => 2
      )
      allow(described_class).to receive(:perform_in)
      add_target(0)

      worker.perform(batch.id)

      expect(batch.targets.reload.map(&:state)).to eq %w(pending)
      expect(described_class).to have_received(:perform_in).once
      expect(FollowImportDispatchObservation.last.load_deferred).to eq true
      expect(FollowImportDispatchObservation.last.effective_execution_budget).to eq 0
    end

    it 'uses fallback when concurrency measurement failed rather than treating it as zero' do
      enable_enforcement(FollowImport::LocalLoadProfile.parse(
                           v2_profile.merge(
                             'fallback' => { 'budget_percent' => 30 },
                             'capacity' => { 'per_push_thread' => 2 }
                           )
                         ))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
        'queues' => { 'push' => { 'size' => 0, 'latency' => 0.1 } },
        'retry_size' => 0,
        'concurrency_error_class' => 'RuntimeError'
      )
      add_target(0)
      add_target(1)
      add_target(2)

      worker.perform(batch.id)

      expect(batch.targets.where(state: :queued).count).to eq 3
      observation = FollowImportDispatchObservation.last
      expect(observation.local_load_state).to eq 'unknown'
      expect(observation.local_load_fallback_used).to eq true
      expect(observation.effective_execution_budget).to eq 3
      expect(observation.load_deferred).to eq false
    end

    it 'releases a queued claim when enqueue fails under a reduced positive budget' do
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
        'queues' => { 'push' => { 'size' => 0, 'latency' => 3.0 } },
        'retry_size' => 0
      )
      first = add_target(0)
      second = add_target(1)
      8.times { |position| add_target(position + 2) }
      calls = 0
      allow(Import::RelationshipWorker).to receive(:perform_async) do
        calls += 1
        raise StandardError, 'redis down' if calls == 2
      end

      expect { worker.perform(batch.id) }.to raise_error(StandardError)

      expect(first.reload.state).to eq 'queued'
      expect(second.reload.state).to eq 'pending'
      expect(second.queued_at).to be_nil
      expect(batch.targets.where(state: :queued).count).to eq 1
      observation = FollowImportDispatchObservation.last
      expect(observation.candidate_count).to eq 4
      expect(observation.claimed_count).to eq 1
      expect(observation.pass_error_class).to eq 'StandardError'
      expect(observation.effective_execution_budget).to eq 4
    end

    it 'schedules at most one deferred recheck per invocation' do
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
        'queues' => { 'push' => { 'size' => 0, 'latency' => 25.0 } },
        'retry_size' => 0
      )
      allow(described_class).to receive(:perform_in)
      add_target(0)

      3.times { described_class.new.perform(batch.id) }

      expect(described_class).to have_received(:perform_in).exactly(3).times
    end

    it 'restores legacy execution on the next pass after the enforcement flag is turned off' do
      profile = FollowImport::LocalLoadProfile.parse(v2_profile)
      allow(FollowImport::LocalLoadProfile).to receive(:from_env).and_return(profile)
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
        'queues' => { 'push' => { 'size' => 0, 'latency' => 25.0 } },
        'retry_size' => 0
      )
      allow(described_class).to receive(:perform_in)
      3.times { |position| add_target(position) }

      allow(FollowImport::ExecutionPolicy).to receive(:local_load_enforcement_enabled?).and_return(true)
      worker.perform(batch.id)
      expect(batch.targets.where(state: :pending).count).to eq 3
      expect(described_class).to have_received(:perform_in).once

      allow(FollowImport::ExecutionPolicy).to receive(:local_load_enforcement_enabled?).and_return(false)
      described_class.new.perform(batch.id)

      expect(batch.targets.where(state: :queued).count).to eq 3
      expect(FollowImportDispatchObservation.last.local_load_enforcement_enabled).to eq false
      expect(FollowImportDispatchObservation.last.load_deferred).to eq false
    end

    it 'retains the Import while load-deferred and can finalize after recovery drains the batch' do
      import = attach_import
      enable_enforcement(FollowImport::LocalLoadProfile.parse(v2_profile))
      allow(FollowImport::ExecutionPolicy).to receive(:execution_batch_size).and_return(10)
      allow(described_class).to receive(:perform_in)
      allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
        { 'queues' => { 'push' => { 'size' => 0, 'latency' => 25.0 } }, 'retry_size' => 0 },
        { 'queues' => { 'push' => { 'size' => 0, 'latency' => 0.1 } }, 'retry_size' => 0 }
      )
      add_target(0)

      worker.perform(batch.id)
      expect(Import.exists?(import.id)).to be true
      expect(described_class).to have_received(:perform_in).once
      expect(batch.targets.reload.map(&:state)).to eq %w(pending)

      described_class.new.perform(batch.id)
      expect(batch.targets.reload.map(&:state)).to eq %w(queued)
      expect(Import.exists?(import.id)).to be false
    end
  end
end
