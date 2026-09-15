# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::DispatchScheduler do
  subject(:scheduler) { described_class.new }

  let(:account)          { Fabricate(:account) }
  let(:importer_subject) { ModerationSubject.for_account!(account) }
  let(:import_record) do
    Import.create!(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt'),
                   follow_import_pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION)
  end
  let(:batch) do
    FollowImportBatch.create!(subject: importer_subject, import_id: import_record.id, imported_at: Time.now.utc,
                              mode: :merge, target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  def add_target(position, **attrs)
    batch.targets.create!({ target_key_hash: "key-#{position}", position: position }.merge(attrs))
  end

  def follow_import_fingerprint
    {
      target_states: FollowImportTarget.order(:id).map { |row| [row.id, row.state, row.queued_at] },
      import_ids: Import.where(id: import_record.id).pluck(:id),
      batch_ids: FollowImportBatch.order(:id).pluck(:id),
    }
  end

  before do
    allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
      'schema_version' => FollowImport::Telemetry::SCHEMA_VERSION,
      'queues' => { 'push' => { 'size' => 1, 'latency' => 0.1 } }
    )
    allow(Import::RelationshipWorker).to receive(:perform_async)
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
    allow(FollowImport::BatchExecutionWorker).to receive(:perform_in)
  end

  shared_examples 'a shadow-only tick' do
    it 'does not change Follow Import execution state or enqueue work' do
      before = follow_import_fingerprint

      expect { perform }.not_to change(FollowImportTarget, :count)

      expect(follow_import_fingerprint).to eq before
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
      expect(ActivityPub::DeliveryWorker).not_to have_received(:perform_async)
      expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
      expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_in)
      expect(Import.exists?(import_record.id)).to be true
    end
  end

  describe 'when shadow is disabled' do
    def perform
      scheduler.call
    end

    before { add_target(0) }

    include_examples 'a shadow-only tick'

    it 'is a cheap no-op: no lease, no planning, no tick row' do
      allow(FollowImport::DispatchLease).to receive(:with_lease)
      allow(FollowImport::DispatchPlan).to receive(:observe)
      allow(FollowImport::DispatchCounts).to receive(:global_pending)
      allow(FollowImport::DispatchTickObserver).to receive(:record)
      allow(FollowImport::FairScheduler).to receive(:new)
      allow(FollowImport::FairnessCursor).to receive(:new)
      allow(FollowImport::PendingBatchSource).to receive(:new)
      allow(FollowImport::LocalLoadGuard).to receive(:evaluate)

      result = scheduler.call

      expect(result.outcome).to eq 'shadow_disabled'
      expect(result.lease_acquired).to be false
      expect(FollowImport::DispatchLease).not_to have_received(:with_lease)
      expect(FollowImport::DispatchPlan).not_to have_received(:observe)
      expect(FollowImport::DispatchCounts).not_to have_received(:global_pending)
      expect(FollowImport::FairScheduler).not_to have_received(:new)
      expect(FollowImport::FairnessCursor).not_to have_received(:new)
      expect(FollowImport::PendingBatchSource).not_to have_received(:new)
      expect(FollowImport::LocalLoadGuard).not_to have_received(:evaluate)
      expect(FollowImport::DispatchTickObserver).not_to have_received(:record)
      expect(FollowImportDispatchTickObservation.count).to eq 0
    end
  end

  describe 'when shadow is enabled and the lease is acquired' do
    def perform
      scheduler.call
    end

    let!(:pending_target) { add_target(0) }
    let!(:queued_target) { add_target(1, state: :queued, queued_at: Time.utc(2026, 1, 2, 3, 4, 5)) }

    before do
      allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
    end

    include_examples 'a shadow-only tick'

    it 'does not call TargetTransitionService#mark_queued' do
      expect_any_instance_of(FollowImport::TargetTransitionService).not_to receive(:mark_queued)

      scheduler.call
    end

    it 'records a shadow_observed tick with claimed_count 0 and leaves the legacy executor responsible' do
      queued_at = queued_target.queued_at

      result = scheduler.call

      expect(result.outcome).to eq 'shadow_observed'
      expect(result.lease_acquired).to be true
      expect(result.plan.claimed_count).to eq 0

      observation = FollowImportDispatchTickObservation.last
      expect(observation.outcome).to eq 'shadow_observed'
      expect(observation.scheduler_mode).to eq 'shadow'
      expect(observation.lease_acquired).to be true
      expect(observation.claimed_count).to eq 0
      expect(observation.local_load_state).to eq 'disabled'
      expect(observation.local_load_recommended_budget).to be_nil
      expect(observation.effective_shadow_plan_budget).to eq FollowImport::ExecutionPolicy.shadow_plan_budget
      expect(observation.planned_count).to eq 1
      expect(observation.planned_owner_count).to eq 1
      expect(observation.planned_batch_count).to eq 1
      expect(observation.executable_owner_count).to eq 1
      expect(observation.executable_batch_count).to eq 1
      expect(observation.global_pending_count).to eq 1
      expect(observation.active_batch_count).to eq 1
      expect(observation.load_snapshot.dig('queues', 'push', 'size')).to eq 1
      expect(observation.execution_config['dispatch_shadow_enabled']).to eq true
      expect(observation.execution_config['shadow_plan_budget']).to eq FollowImport::ExecutionPolicy.shadow_plan_budget
      expect(observation.execution_config['plan_algorithm']).to eq 'account_first_rr'
      expect(observation.execution_config['dispatch_shadow_interval']).to eq FollowImport::ExecutionPolicy.dispatch_shadow_interval.to_i
      expect(observation.execution_config['execution_batch_size']).to eq FollowImport::ExecutionPolicy.execution_batch_size
      expect(result.plan.planned_count).to eq 1
      expect(result.plan.entries.first.target_id).to eq pending_target.id
      expect(observation.tick_id).to be_present

      expect(pending_target.reload.state).to eq 'pending'
      expect(queued_target.reload.state).to eq 'queued'
      expect(queued_target.queued_at).to eq queued_at
    end

    it 'still allows BatchExecutionWorker to claim after the shadow tick' do
      allow(Sidekiq::Queue).to receive(:new).and_return(instance_double(Sidekiq::Queue, size: 1, latency: 0.2))
      allow(Sidekiq::Stats).to receive(:new).and_return(instance_double(Sidekiq::Stats, retry_size: 0))
      allow(Sidekiq::ProcessSet).to receive(:new).and_return([])
      allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for)
        .and_return({ acct: 'acct@remote.test', options: { 'show_reblogs' => true } })
      allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call)
        .and_return({ 'proposed_friction' => 'allow' })

      scheduler.call
      expect(pending_target.reload.state).to eq 'pending'

      FollowImport::BatchExecutionWorker.new.perform(batch.id)

      expect(pending_target.reload.state).to eq 'queued'
      expect(Import::RelationshipWorker).to have_received(:perform_async)
    end
  end

  describe 'when the advisory lease is busy' do
    def perform
      scheduler.call
    end

    before do
      allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
      allow(FollowImport::DispatchLease).to receive(:with_lease).and_return(FollowImport::DispatchLease::BUSY)
      add_target(0)
    end

    include_examples 'a shadow-only tick'

    it 'records lease_busy with claimed_count 0 and does not plan work' do
      allow(FollowImport::DispatchPlan).to receive(:observe)

      result = scheduler.call

      expect(result.outcome).to eq 'lease_busy'
      expect(result.lease_acquired).to be false
      expect(FollowImport::DispatchPlan).not_to have_received(:observe)

      observation = FollowImportDispatchTickObservation.last
      expect(observation.outcome).to eq 'lease_busy'
      expect(observation.lease_acquired).to be false
      expect(observation.claimed_count).to eq 0
      expect(observation.planned_count).to be_nil
      expect(observation.local_load_state).to be_nil
      expect(observation.local_load_recommended_budget).to be_nil
      expect(observation.global_pending_count).to be_nil
    end
  end

  describe 'when LoadSnapshot capture fails' do
    def perform
      scheduler.call
    end

    before do
      allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
      allow(FollowImport::LoadSnapshot).to receive(:capture).and_raise(StandardError, 'redis down')
      add_target(0)
    end

    include_examples 'a shadow-only tick'

    it 'continues the shadow tick and stores NULL for the unavailable snapshot' do
      result = scheduler.call

      expect(result.outcome).to eq 'shadow_observed'
      observation = FollowImportDispatchTickObservation.last
      expect(observation.load_snapshot).to be_nil
      expect(observation.metadata['load_snapshot_error_class']).to eq 'StandardError'
      expect(observation.claimed_count).to eq 0
      expect(observation.global_pending_count).to eq 1
    end
  end

  describe 'when a backlog count cannot be measured' do
    before do
      allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
      allow(FollowImport::DispatchCounts).to receive(:global_pending).and_return(nil)
      allow(FollowImport::DispatchCounts).to receive(:active_batches).and_return(nil)
      add_target(0)
    end

    it 'stores NULL rather than coercing an unavailable count to 0' do
      scheduler.call

      observation = FollowImportDispatchTickObservation.last
      expect(observation.global_pending_count).to be_nil
      expect(observation.active_batch_count).to be_nil
      expect(observation.claimed_count).to eq 0
    end
  end

  describe 'when telemetry insert fails' do
    def perform
      scheduler.call
    end

    before do
      allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
      allow(FollowImportDispatchTickObservation).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')
      add_target(0)
    end

    include_examples 'a shadow-only tick'

    it 'does not raise solely because tick telemetry failed' do
      expect { scheduler.call }.not_to raise_error
    end
  end

  describe 'when the shadow tick raises internally' do
    before do
      allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
      allow(FollowImport::DispatchPlan).to receive(:observe).and_raise(StandardError, 'plan exploded')
      add_target(0)
    end

    it 'records shadow_error, claims nothing, and releases the advisory lease' do
      result = scheduler.call

      expect(result.outcome).to eq 'shadow_error'
      expect(FollowImportTarget.order(:id).map(&:state)).to eq %w(pending)
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)

      observation = FollowImportDispatchTickObservation.last
      expect(observation.outcome).to eq 'shadow_error'
      expect(observation.lease_acquired).to be true
      expect(observation.claimed_count).to eq 0
      expect(observation.error_class).to eq 'StandardError'
      expect(observation.planned_count).to be_nil

      reacquired = false
      expect(FollowImport::DispatchLease.with_lease { reacquired = true }).to be true
      expect(reacquired).to be true
    end
  end

  describe 'when Redis cursor persistence fails' do
    def perform
      scheduler.call
    end

    before do
      allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
      allow_any_instance_of(FollowImport::FairnessCursor).to receive(:write).and_return(false)
      add_target(0)
    end

    include_examples 'a shadow-only tick'

    it 'still records a shadow observation from a conservative cursor' do
      result = scheduler.call

      expect(result.outcome).to eq 'shadow_observed'
      expect(result.plan.planned_count).to eq 1
      expect(result.plan.claimed_count).to eq 0
      expect(FollowImportDispatchTickObservation.last.fairness_state_source).to eq 'persist_failed'
    end
  end

  describe 'account-first integration' do
    before do
      allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
      allow(FollowImport::ExecutionPolicy).to receive(:shadow_plan_budget).and_return(3)
    end

    def import_for(account)
      FollowImportBatch.create!(
        subject: ModerationSubject.for_account!(account),
        imported_at: Time.now.utc,
        mode: :merge,
        target_count: 0,
        resolved_target_count: 0,
        unresolved_target_count: 0
      )
    end

    it 'records planned_count 0 when the lease is acquired and nothing is pending' do
      result = scheduler.call
      observation = FollowImportDispatchTickObservation.last

      expect(result.outcome).to eq 'shadow_observed'
      expect(result.plan.planned_count).to eq 0
      expect(result.plan.planned_owner_count).to eq 0
      expect(result.plan.executable_owner_count).to eq 0
      expect(result.plan.claimed_count).to eq 0
      expect(observation.planned_count).to eq 0
      expect(observation.planned_owner_count).to eq 0
      expect(observation.executable_owner_count).to eq 0
      expect(observation.claimed_count).to eq 0
    end

    it 'plans pending work, records aggregates, and leaves legacy claiming intact' do
      other_account = Fabricate(:account)
      other_batch = import_for(other_account)
      other_batch.targets.create!(target_key_hash: 'other-0', position: 0, destination_domain: 'b.test')
      add_target(0, destination_domain: 'a.test')

      result = scheduler.call
      observation = FollowImportDispatchTickObservation.last

      expect(result.plan.planned_count).to eq 2
      expect(result.plan.claimed_count).to eq 0
      expect(observation.planned_count).to eq 2
      expect(observation.claimed_count).to eq 0
      expect(observation.planned_owner_count).to eq 2
      expect(observation.executable_owner_count).to eq 2
      expect(observation.unique_destination_count).to eq 2
      expect(batch.targets.reload.map(&:state)).to eq %w(pending)
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    end

    it 'does not load every pending target to fill a small plan budget' do
      3.times do
        extra = import_for(Fabricate(:account))
        20.times { |position| extra.targets.create!(target_key_hash: "t-#{extra.id}-#{position}", position: position) }
      end

      sql = []
      callback = lambda do |*_args, payload|
        query = payload[:sql]
        sql << query if query.include?('follow_import_targets') && query.include?('SELECT') && !query.include?('COUNT')
      end

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        scheduler.call
      end

      target_row_selects = sql.reject { |query| query.include?('DISTINCT') }
      expect(target_row_selects).not_to be_empty
      expect(target_row_selects).to all(match(/LIMIT/i))
    end

    it 'does not issue one target-window query per active owner before planning' do
      owner_count = 100
      budget = 3
      owner_count.times do |index|
        extra = import_for(Fabricate(:account))
        extra.targets.create!(target_key_hash: "many-#{index}", position: 0, destination_domain: 'many.test')
      end

      window_selects = []
      callback = lambda do |*_args, payload|
        query = payload[:sql]
        next unless query.include?('follow_import_targets')
        next unless query.include?('SELECT')
        next if query.include?('COUNT') || query.include?('DISTINCT')
        next unless query.match?(/LIMIT/i)

        window_selects << query
      end

      result = nil
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        result = scheduler.call
      end

      expect(result.plan.planned_count).to eq budget
      expect(result.plan.planned_owner_count).to eq budget
      expect(result.plan.executable_owner_count).to eq owner_count
      expect(result.plan.executable_batch_count).to eq owner_count
      expect(FollowImportDispatchTickObservation.last.executable_owner_count).to eq owner_count
      expect(FollowImportDispatchTickObservation.last.planned_owner_count).to eq budget
      expect(window_selects.size).to be <= (budget * 2)
      expect(window_selects.size).to be < (owner_count / 4)
    end

    it 'skips a batch with no owner without crashing' do
      orphan = import_for(Fabricate(:account))
      orphan.targets.create!(target_key_hash: 'orphan', position: 0)
      allow_any_instance_of(FollowImportBatch).to receive(:for_account).and_return(nil)

      result = scheduler.call

      expect(result.outcome).to eq 'shadow_observed'
      expect(result.plan.skipped_missing_owner_count).to be >= 1
      expect(result.plan.claimed_count).to eq 0
    end
  end

  describe 'local-load shadow' do
    def perform
      scheduler.call
    end

    def profile(payload)
      FollowImport::LocalLoadProfile.parse(payload)
    end

    def enable_local_load(injected)
      allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
      allow(FollowImport::ExecutionPolicy).to receive(:local_load_shadow_enabled?).and_return(true)
      allow(FollowImport::ExecutionPolicy).to receive(:shadow_plan_budget).and_return(10)
      allow(FollowImport::LocalLoadProfile).to receive(:from_env).and_return(injected)
    end

    it 'keeps the PR B budget when the local-load flag is off' do
      allow(FollowImport::ExecutionPolicy).to receive(:dispatch_shadow_enabled?).and_return(true)
      allow(FollowImport::ExecutionPolicy).to receive(:shadow_plan_budget).and_return(10)
      add_target(0)
      allow(FollowImport::FairScheduler).to receive(:new).and_call_original

      result = scheduler.call

      expect(FollowImport::FairScheduler).to have_received(:new).with(hash_including(budget: 10))
      expect(result.plan.local_load_state).to eq 'disabled'
      expect(result.plan.effective_shadow_plan_budget).to eq 10
      expect(result.plan.claimed_count).to eq 0
    end

    it 'keeps the PR B budget when the profile is unconfigured' do
      enable_local_load(profile(nil))
      add_target(0)
      allow(FollowImport::FairScheduler).to receive(:new).and_call_original

      result = scheduler.call
      observation = FollowImportDispatchTickObservation.last

      expect(FollowImport::FairScheduler).to have_received(:new).with(hash_including(budget: 10))
      expect(observation.local_load_state).to eq 'unconfigured'
      expect(observation.local_load_recommended_budget).to be_nil
      expect(observation.effective_shadow_plan_budget).to eq 10
      expect(result.plan.claimed_count).to eq 0
    end

    it 'uses the full base budget for a healthy configured snapshot' do
      enable_local_load(profile(
                          'version' => 1,
                          'levels' => { 'busy' => { 'budget_percent' => 50, 'push' => { 'latency' => 5 } } }
                        ))
      add_target(0)
      allow(FollowImport::FairScheduler).to receive(:new).and_call_original

      result = scheduler.call

      expect(FollowImport::FairScheduler).to have_received(:new).with(hash_including(budget: 10))
      expect(result.plan.local_load_state).to eq 'normal'
      expect(result.plan.effective_shadow_plan_budget).to eq 10
      expect(result.plan.planned_count).to eq 1
      expect(result.plan.claimed_count).to eq 0
    end

    it 'shrinks only the shadow plan when a busy profile recommends half' do
      enable_local_load(profile(
                          'version' => 1,
                          'levels' => { 'busy' => { 'budget_percent' => 50, 'push' => { 'latency' => 0.05 } } }
                        ))
      8.times { |position| add_target(position) }
      allow(FollowImport::FairScheduler).to receive(:new).and_call_original

      result = scheduler.call
      observation = FollowImportDispatchTickObservation.last

      expect(FollowImport::FairScheduler).to have_received(:new).with(hash_including(budget: 5))
      expect(observation.local_load_state).to eq 'busy'
      expect(observation.local_load_recommended_budget).to eq 5
      expect(observation.effective_shadow_plan_budget).to eq 5
      expect(observation.local_load_budget_percent).to eq 50
      expect(result.plan.planned_count).to eq 5
      expect(result.plan.claimed_count).to eq 0
      expect(batch.targets.reload.map(&:state).uniq).to eq %w(pending)
    end

    it 'records a shadow skip without changing real Follow Import work' do
      enable_local_load(profile(
                          'version' => 1,
                          'levels' => { 'overloaded' => { 'budget_percent' => 0, 'push' => { 'latency' => 0.05 } } }
                        ))
      pending_target = add_target(0)

      result = scheduler.call
      observation = FollowImportDispatchTickObservation.last

      expect(result.plan.planned_count).to eq 0
      expect(result.plan.claimed_count).to eq 0
      expect(observation.local_load_state).to eq 'overloaded'
      expect(observation.local_load_recommended_budget).to eq 0
      expect(observation.effective_shadow_plan_budget).to eq 0
      expect(observation.local_load_would_skip).to be true
      expect(pending_target.reload.state).to eq 'pending'
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    end

    it 'does not treat a shadow skip as a real skip: the legacy worker can still claim' do
      enable_local_load(profile(
                          'version' => 1,
                          'levels' => { 'overloaded' => { 'budget_percent' => 0, 'push' => { 'latency' => 0.05 } } }
                        ))
      pending_target = add_target(0)
      allow(Sidekiq::Queue).to receive(:new).and_return(instance_double(Sidekiq::Queue, size: 1, latency: 0.2))
      allow(Sidekiq::Stats).to receive(:new).and_return(instance_double(Sidekiq::Stats, retry_size: 0))
      allow(Sidekiq::ProcessSet).to receive(:new).and_return([])
      allow_any_instance_of(FollowImport::ImportUnitResolver).to receive(:work_for)
        .and_return({ acct: 'acct@remote.test', options: { 'show_reblogs' => true } })
      allow_any_instance_of(Moderation::AdaptiveFollowGateDecisionService).to receive(:call)
        .and_return({ 'proposed_friction' => 'allow' })

      scheduler.call
      expect(pending_target.reload.state).to eq 'pending'
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)

      FollowImport::BatchExecutionWorker.new.perform(batch.id)

      expect(pending_target.reload.state).to eq 'queued'
      expect(Import::RelationshipWorker).to have_received(:perform_async)
    end

    it 'falls back to the base shadow budget when a required measurement is missing' do
      enable_local_load(profile(
                          'version' => 1,
                          'levels' => { 'busy' => { 'budget_percent' => 50, 'push' => { 'latency' => 1 } } }
                        ))
      allow(FollowImport::LoadSnapshot).to receive(:capture).and_return(
        'queues' => { 'push' => { 'error_class' => 'RuntimeError' } }
      )
      add_target(0)
      allow(FollowImport::FairScheduler).to receive(:new).and_call_original

      result = scheduler.call
      observation = FollowImportDispatchTickObservation.last

      expect(FollowImport::FairScheduler).to have_received(:new).with(hash_including(budget: 10))
      expect(observation.local_load_state).to eq 'unknown'
      expect(observation.local_load_recommended_budget).to be_nil
      expect(observation.local_load_measurement_complete).to be false
      expect(observation.effective_shadow_plan_budget).to eq 10
      expect(result.plan.claimed_count).to eq 0
    end
  end
end

