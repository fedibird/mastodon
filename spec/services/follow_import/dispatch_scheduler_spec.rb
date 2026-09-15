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

      result = scheduler.call

      expect(result.outcome).to eq 'shadow_disabled'
      expect(result.lease_acquired).to be false
      expect(FollowImport::DispatchLease).not_to have_received(:with_lease)
      expect(FollowImport::DispatchPlan).not_to have_received(:observe)
      expect(FollowImport::DispatchCounts).not_to have_received(:global_pending)
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
      expect(observation.global_pending_count).to eq 1
      expect(observation.active_batch_count).to eq 1
      expect(observation.load_snapshot.dig('queues', 'push', 'size')).to eq 1
      expect(observation.execution_config['dispatch_shadow_enabled']).to eq true
      expect(observation.execution_config['execution_batch_size']).to eq FollowImport::ExecutionPolicy.execution_batch_size
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

      reacquired = false
      expect(FollowImport::DispatchLease.with_lease { reacquired = true }).to be true
      expect(reacquired).to be true
    end
  end
end
