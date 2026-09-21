# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::DispatchScheduler, 'authoritative global mode' do # rubocop:disable Metrics/BlockLength
  subject(:scheduler) { described_class.new }

  def create_import(account)
    Import.create!(
      account: account,
      type: 'following',
      data: attachment_fixture('new-following-imports.txt'),
      follow_import_pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION
    )
  end

  def create_batch(account, owner:, import: nil, cohort: :operational)
    FollowImportBatch.create!(
      subject: ModerationSubject.for_account!(account),
      import_id: (import || create_import(account)).id,
      imported_at: Time.now.utc,
      mode: :merge,
      dispatch_owner: owner,
      dispatch_cohort: cohort,
      target_count: 0,
      resolved_target_count: 0,
      unresolved_target_count: 0
    )
  end

  def add_target(batch, position, **attrs)
    batch.targets.create!({ target_key_hash: "key-#{batch.id}-#{position}", position: position }.merge(attrs))
  end

  def enable_global
    allow(FollowImport::ExecutionPolicy).to receive(:dispatch_global_enabled?).and_return(true)
  end

  before do
    enable_global
    allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
      'schema_version' => FollowImport::Telemetry::SCHEMA_VERSION,
      'queues' => { 'push' => { 'size' => 1, 'latency' => 0.1 } }
    )
    allow(Import::RelationshipWorker).to receive(:perform_async)
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_in)
    allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for) do |_resolver, target|
      { acct: "acct-#{target.id}@remote.test", options: { 'show_reblogs' => true } }
    end
  end

  it 'claims a scheduler-owned pending target and does not enqueue BatchExecutionWorker' do
    account = Fabricate(:account)
    batch = create_batch(account, owner: :scheduler)
    target = add_target(batch, 0)

    result = scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(result.outcome).to eq 'global_observed'
    expect(target.reload.state).to eq 'queued'
    expect(Import::RelationshipWorker).to have_received(:perform_async).with(
      account.id,
      "acct-#{target.id}@remote.test",
      'follow',
      hash_including(
        'import_batch_id' => batch.id,
        'follow_import_target_id' => target.id
      )
    )
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_in)
    expect(observation.scheduler_mode).to eq 'global'
    expect(observation.claimed_count).to eq 1
    expect(observation.planned_count).to eq 1
    expect(observation.lease_acquired).to be true
  end

  it 'never includes a legacy-owned batch in the authoritative plan' do
    legacy_account = Fabricate(:account)
    scheduler_account = Fabricate(:account)
    legacy_batch = create_batch(legacy_account, owner: :legacy)
    scheduler_batch = create_batch(scheduler_account, owner: :scheduler)
    legacy_target = add_target(legacy_batch, 0)
    scheduler_target = add_target(scheduler_batch, 0)

    scheduler.call

    expect(scheduler_target.reload.state).to eq 'queued'
    expect(legacy_target.reload.state).to eq 'pending'

    allow(Sidekiq::Queue).to receive(:new).and_return(instance_double(Sidekiq::Queue, size: 1, latency: 0.2))
    allow(Sidekiq::Stats).to receive(:new).and_return(instance_double(Sidekiq::Stats, retry_size: 0))
    allow(Sidekiq::ProcessSet).to receive(:new).and_return([])
    allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call)
      .and_return({ 'proposed_friction' => 'allow' })

    FollowImport::BatchExecutionWorker.new.perform(legacy_batch.id)
    expect(legacy_target.reload.state).to eq 'queued'

    FollowImport::BatchExecutionWorker.new.perform(scheduler_batch.id)
    expect(scheduler_target.reload.state).to eq 'queued'
    expect(Import::RelationshipWorker).to have_received(:perform_async).twice
  end

  it 'claims only operational scheduler-owned pending and leaves other cohorts pending' do
    historical_scheduler = create_batch(Fabricate(:account), owner: :scheduler, cohort: :historical)
    operational_legacy = create_batch(Fabricate(:account), owner: :legacy, cohort: :operational)
    operational_scheduler = create_batch(Fabricate(:account), owner: :scheduler, cohort: :operational)
    historical_target = add_target(historical_scheduler, 0)
    legacy_target = add_target(operational_legacy, 0)
    scheduler_target = add_target(operational_scheduler, 0)

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(scheduler_target.reload.state).to eq 'queued'
    expect(historical_target.reload.state).to eq 'pending'
    expect(legacy_target.reload.state).to eq 'pending'
    expect(observation.claimed_count).to eq 1
    expect(observation.planned_count).to eq 1
    expect(observation.global_pending_count).to eq 3
    expect(observation.active_batch_count).to eq 3
    expect(observation.historical_pending_count).to eq 1
    expect(observation.historical_active_batch_count).to eq 1
    expect(observation.operational_pending_count).to eq 2
    expect(observation.operational_active_batch_count).to eq 2
    expect(observation.planning_pending_count).to eq 1
    expect(observation.planning_active_batch_count).to eq 1
    expect(observation.execution_config['backlog_scope_strategy']).to eq 'dispatch_cohort_v1'
    expect(Import::RelationshipWorker).to have_received(:perform_async).once
  end

  it 'shares a finite global budget across equal accounts' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    first = Fabricate(:account)
    second = Fabricate(:account)
    first_batch = create_batch(first, owner: :scheduler)
    second_batch = create_batch(second, owner: :scheduler)
    20.times { |position| add_target(first_batch, position) }
    20.times { |position| add_target(second_batch, position) }

    scheduler.call

    expect(first_batch.targets.where(state: :queued).count).to eq 5
    expect(second_batch.targets.where(state: :queued).count).to eq 5
    expect(FollowImportDispatchTickObservation.last.claimed_count).to eq 10
  end

  it 'does not give a split CSV a larger top-level global share' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    first = Fabricate(:account)
    second = Fabricate(:account)
    10.times do
      batch = create_batch(first, owner: :scheduler)
      5.times { |position| add_target(batch, position) }
    end
    single = create_batch(second, owner: :scheduler)
    20.times { |position| add_target(single, position) }

    scheduler.call

    first_claimed = FollowImportTarget.joins(:batch).merge(FollowImportBatch.scheduler_owned)
                                      .where(state: :queued, follow_import_batches: { subject_id: ModerationSubject.for_account!(first).id })
                                      .count
    second_claimed = single.targets.where(state: :queued).count

    expect((first_claimed - second_claimed).abs).to be <= 1
    expect(first_claimed + second_claimed).to eq 10
  end

  it 'still binds the finite global base budget when local-load enforcement is off' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(3)
    allow(FollowImport::ExecutionPolicy).to receive(:local_load_enforcement_enabled?).and_return(false)
    account = Fabricate(:account)
    batch = create_batch(account, owner: :scheduler)
    6.times { |position| add_target(batch, position) }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(batch.targets.where(state: :queued).count).to eq 3
    expect(observation.global_base_budget).to eq 3
    expect(observation.effective_global_budget).to eq 3
    expect(observation.claimed_count).to eq 3
  end

  it 'shrinks real claims to the local-load recommendation' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    allow(FollowImport::LocalLoadEnforcement).to receive(:evaluate).and_return(
      FollowImport::LocalLoadEnforcement::Result.new(
        enabled: true,
        configured: true,
        decision: FollowImport::LocalLoadDecision.new(
          {
            state: 'busy',
            budget_percent: 40,
            recommended_budget: 4,
            would_skip: false,
            measurement_complete: true,
            profile_version: 2,
            profile_source: 'injected',
            profile_digest: 'd',
            reasons: [],
          }
        ),
        base_budget: 10,
        effective_budget: 4,
        fallback_used: false
      )
    )
    account = Fabricate(:account)
    batch = create_batch(account, owner: :scheduler)
    8.times { |position| add_target(batch, position) }

    scheduler.call

    expect(batch.targets.where(state: :queued).count).to eq 4
    expect(FollowImportDispatchTickObservation.last.claimed_count).to eq 4
    expect(FollowImportDispatchTickObservation.last.effective_global_budget).to eq 4
  end

  it 'claims nothing on a global zero budget and does not enqueue deferred BatchExecutionWorker jobs' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    allow(FollowImport::LocalLoadEnforcement).to receive(:evaluate).and_return(
      FollowImport::LocalLoadEnforcement::Result.new(
        enabled: true,
        configured: true,
        decision: FollowImport::LocalLoadDecision.new(
          {
            state: 'overloaded',
            budget_percent: 0,
            recommended_budget: 0,
            would_skip: true,
            measurement_complete: true,
            profile_version: 2,
            profile_source: 'injected',
            profile_digest: 'd',
            reasons: [],
          }
        ),
        base_budget: 10,
        effective_budget: 0,
        fallback_used: false
      )
    )
    account = Fabricate(:account)
    import_record = create_import(account)
    batch = create_batch(account, owner: :scheduler, import: import_record)
    targets = 3.times.map { |position| add_target(batch, position) }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(targets.map { |target| target.reload.state }.uniq).to eq %w(pending)
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_in)
    expect(Import.exists?(import_record.id)).to be true
    expect(observation.claimed_count).to eq 0
    expect(observation.global_base_budget).to eq 10
    expect(observation.effective_global_budget).to eq 0
    expect(observation.planned_count).to eq 0
    expect(observation.local_load_state).to eq 'overloaded'
    expect(observation.local_load_fallback_used).to eq false
    expect(observation.executable_owner_count).to be_nil
    expect(observation.executable_batch_count).to be_nil
  end

  it 'does not discover pending work or move the fairness cursor on a GLOBAL zero-budget tick' do # rubocop:disable Metrics/BlockLength
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    allow(FollowImport::LocalLoadEnforcement).to receive(:evaluate).and_return(
      FollowImport::LocalLoadEnforcement::Result.new(
        enabled: true,
        configured: true,
        decision: FollowImport::LocalLoadDecision.new(
          {
            state: 'overloaded',
            budget_percent: 0,
            recommended_budget: 0,
            would_skip: true,
            measurement_complete: true,
            profile_version: 2,
            profile_source: 'injected',
            profile_digest: 'd',
            reasons: [],
          }
        ),
        base_budget: 10,
        effective_budget: 0,
        fallback_used: false
      )
    )
    account = Fabricate(:account)
    import_record = create_import(account)
    batch = create_batch(account, owner: :scheduler, import: import_record)
    add_target(batch, 0)
    allow(FollowImport::PendingBatchSource).to receive(:new).and_call_original
    allow(FollowImport::FairScheduler).to receive(:new)
    allow(FollowImport::PendingTargetFeed).to receive(:new)
    allow(FollowImport::FairnessCursor).to receive(:new).and_call_original
    allow(FollowImport::DispatchCounts).to receive(:global_pending)
    allow(FollowImport::DispatchCounts).to receive(:active_batches)
    allow(FollowImport::DispatchCounts).to receive(:backlog_snapshot)

    target_selects = []
    callback = lambda do |*_args, payload|
      query = payload[:sql]
      next unless query.include?('follow_import_targets')
      next unless query.include?('SELECT')

      target_selects << query
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      scheduler.call
    end

    expect(FollowImport::PendingBatchSource).not_to have_received(:new)
    expect(FollowImport::FairScheduler).not_to have_received(:new)
    expect(FollowImport::PendingTargetFeed).not_to have_received(:new)
    expect(FollowImport::FairnessCursor).not_to have_received(:new)
    expect(FollowImport::DispatchCounts).not_to have_received(:global_pending)
    expect(FollowImport::DispatchCounts).not_to have_received(:active_batches)
    expect(FollowImport::DispatchCounts).not_to have_received(:backlog_snapshot)
    expect(target_selects).to be_empty
    expect(batch.targets.reload.map(&:state).uniq).to eq %w(pending)
    expect(Import.exists?(import_record.id)).to be true
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_in)
    observation = FollowImportDispatchTickObservation.last
    expect(observation.claimed_count).to eq 0
    expect(observation.planned_count).to eq 0
    expect(observation.executable_owner_count).to be_nil
    expect(observation.executable_batch_count).to be_nil
    expect(observation.global_pending_count).to be_nil
    expect(observation.active_batch_count).to be_nil
    expect(observation.historical_pending_count).to be_nil
    expect(observation.operational_pending_count).to be_nil
    expect(observation.planning_pending_count).to be_nil
    expect(observation.historical_active_batch_count).to be_nil
    expect(observation.operational_active_batch_count).to be_nil
    expect(observation.planning_active_batch_count).to be_nil
    expect(observation.effective_global_budget).to eq 0
    expect(observation.local_load_state).to eq 'overloaded'
  end

  it 'applies the explicit v2 fallback when the snapshot cannot be measured' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(10)
    allow(FollowImport::ExecutionPolicy).to receive(:local_load_enforcement_enabled?).and_return(true)
    allow(FollowImport::LocalLoadProfile).to receive(:from_env).and_return(
      FollowImport::LocalLoadProfile.parse(
        {
          'version' => 2,
          'levels' => { 'busy' => { 'budget_percent' => 50, 'push' => { 'latency' => 1 } } },
          'fallback' => { 'budget_percent' => 20 },
        }
      )
    )
    allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
      'queues' => { 'push' => { 'error_class' => 'RuntimeError' } }
    )
    account = Fabricate(:account)
    batch = create_batch(account, owner: :scheduler)
    6.times { |position| add_target(batch, position) }

    scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(observation.local_load_state).to eq 'unknown'
    expect(observation.local_load_fallback_used).to eq true
    expect(observation.effective_global_budget).to eq 2
    expect(observation.claimed_count).to eq 2
    expect(batch.targets.where(state: :queued).count).to eq 2
  end

  it 'preserves partial claimed_count when a later enqueue fails' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(5)
    account = Fabricate(:account)
    batch = create_batch(account, owner: :scheduler)
    targets = 5.times.map { |position| add_target(batch, position) }
    calls = 0
    allow(Import::RelationshipWorker).to receive(:perform_async) do
      calls += 1
      raise 'redis down' if calls == 3

      true
    end

    result = scheduler.call
    observation = FollowImportDispatchTickObservation.last

    expect(result.outcome).to eq 'global_error'
    expect(targets[0].reload.state).to eq 'queued'
    expect(targets[1].reload.state).to eq 'queued'
    expect(targets[2].reload.state).to eq 'pending'
    expect(targets[3].reload.state).to eq 'pending'
    expect(targets[4].reload.state).to eq 'pending'
    expect(observation.scheduler_mode).to eq 'global'
    expect(observation.lease_acquired).to be true
    expect(observation.planned_count).to eq 5
    expect(observation.claimed_count).to eq 2
    expect(observation.error_class).to eq 'RuntimeError'
    expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_in)
  end

  it 'eventually claims a later recoverable row after an unrecoverable head-of-line target' do
    allow(FollowImport::ExecutionPolicy).to receive(:global_dispatch_budget).and_return(1)
    account = Fabricate(:account)
    batch = create_batch(account, owner: :scheduler)
    first = add_target(batch, 0)
    second = add_target(batch, 1)
    allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for) do |_resolver, target|
      next if target.id == first.id

      { acct: "acct-#{target.id}@remote.test", options: {} }
    end

    first_tick = scheduler.call
    expect(first.reload.state).to eq 'pending'
    expect(second.reload.state).to eq 'pending'
    expect(first_tick.plan.claimed_count).to eq 0
    expect(first_tick.plan.skipped_unrecoverable_count).to eq 1

    second_tick = scheduler.call
    expect(first.reload.state).to eq 'pending'
    expect(second.reload.state).to eq 'queued'
    expect(second_tick.plan.claimed_count).to eq 1
  end

  it 'does not consult the follow gate or shadow local-load flag for real claims' do
    allow(FollowImport::ExecutionPolicy).to receive(:local_load_shadow_enabled?).and_return(true)
    allow(FollowImport::ExecutionGate).to receive(:for_account)
    allow(FollowImport::LocalLoadBudget).to receive(:resolve)
    account = Fabricate(:account)
    batch = create_batch(account, owner: :scheduler)
    add_target(batch, 0)

    scheduler.call

    expect(FollowImport::ExecutionGate).not_to have_received(:for_account)
    expect(FollowImport::LocalLoadBudget).not_to have_received(:resolve)
    expect(batch.targets.first.reload.state).to eq 'queued'
  end
end
