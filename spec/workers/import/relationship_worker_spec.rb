# frozen_string_literal: true

require 'rails_helper'

describe Import::RelationshipWorker do
  let(:account) { Fabricate(:account) }
  let(:target)  { Fabricate(:account, username: 'import_target') }

  before do
    resolver = instance_double(ResolveAccountService, call: target)
    allow(ResolveAccountService).to receive(:new).and_return(resolver)
  end

  describe 'follow imports carrying an import_batch_id' do
    it 'passes the import_batch_id through to FollowService' do
      follow_service = instance_double(FollowService, call: nil)
      allow(FollowService).to receive(:new).and_return(follow_service)

      described_class.new.perform(account.id, 'import_target', 'follow', { 'import_batch_id' => 99, 'reblogs' => true })

      expect(follow_service).to have_received(:call)
        .with(account, target, hash_including(import_batch_id: 99))
    end
  end

  describe 'ordinary follows (no import context)' do
    it 'does not pass an import_batch_id to FollowService' do
      follow_service = instance_double(FollowService, call: nil)
      allow(FollowService).to receive(:new).and_return(follow_service)

      described_class.new.perform(account.id, 'import_target', 'follow', { 'reblogs' => true })

      expect(follow_service).to have_received(:call)
        .with(account, target, hash_excluding(:import_batch_id))
    end
  end

  describe 'when a follow-import target cannot be resolved' do
    let(:batch) do
      FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                                target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
    end
    let(:import_target) do
      t = batch.targets.create!(target_key_hash: 'unresolvable-key', destination_domain: 'unknown.example', position: 0)
      FollowImport::TargetTransitionService.new.mark_queued(t)
      t
    end

    before do
      resolver = instance_double(ResolveAccountService, call: nil)
      allow(ResolveAccountService).to receive(:new).and_return(resolver)
    end

    it 'marks the claimed target delivery_failed so it does not sit stuck at queued' do
      described_class.new.perform(account.id, 'ghost@unknown.example', 'follow', { 'follow_import_target_id' => import_target.id })

      import_target.reload
      expect(import_target.state).to eq 'delivery_failed'
      expect(import_target.failure_code).to eq 'account_unresolved'
    end

    it 'does nothing for a non-follow relationship with no follow-import target' do
      expect { described_class.new.perform(account.id, 'ghost@unknown.example', 'block', {}) }.not_to raise_error
    end

    it 'records an unresolved_or_unavailable resolve observation for a follow-import target' do
      expect {
        described_class.new.perform(account.id, 'ghost@unknown.example', 'follow', { 'follow_import_target_id' => import_target.id })
      }.to change(FollowImportTransportObservation, :count).by(1)

      observation = FollowImportTransportObservation.last
      expect(observation.phase).to eq 'resolve_account'
      expect(observation.target_id).to eq import_target.id
      expect(observation.batch_id).to eq batch.id
      expect(observation.outcome).to eq 'unresolved_or_unavailable'
      expect(observation.destination_domain).to eq 'unknown.example'
      expect(observation.error_class).to be_nil
    end
  end

  describe 'follow-import resolution observation' do
    let(:batch) do
      FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                                target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
    end
    let(:import_target) do
      t = batch.targets.create!(
        target_key_hash: FollowImportTarget.key_hash('import_target@example.com'),
        destination_domain: 'example.com',
        position: 0
      )
      FollowImport::TargetTransitionService.new.mark_queued(t)
      t
    end

    it 'records a resolved observation when the follow-import target resolves' do
      follow_service = instance_double(FollowService, call: nil)
      allow(FollowService).to receive(:new).and_return(follow_service)

      expect {
        described_class.new.perform(account.id, 'import_target@example.com', 'follow', { 'follow_import_target_id' => import_target.id })
      }.to change(FollowImportTransportObservation, :count).by(1)

      observation = FollowImportTransportObservation.last
      expect(observation.phase).to eq 'resolve_account'
      expect(observation.outcome).to eq 'resolved'
      expect(observation.target_id).to eq import_target.id
      expect(observation.destination_domain).to eq 'example.com'
      expect(observation.enqueued_at).to be_within(1.second).of(import_target.queued_at)
      expect(observation.queue_wait_ms).to be >= 0
      expect(observation.request_started_at).to be_nil
      expect(observation.request_duration_ms).to be_nil
      expect(observation.metadata['duration_kind']).to eq 'resolve_path'
      expect(follow_service).to have_received(:call)
    end

    it 'does not observe ordinary follows without a follow-import target id' do
      follow_service = instance_double(FollowService, call: nil)
      allow(FollowService).to receive(:new).and_return(follow_service)

      expect {
        described_class.new.perform(account.id, 'import_target', 'follow', { 'reblogs' => true })
      }.not_to change(FollowImportTransportObservation, :count)
    end

    it 'still follows when telemetry insert fails' do
      follow_service = instance_double(FollowService, call: nil)
      allow(FollowService).to receive(:new).and_return(follow_service)
      allow(FollowImportTransportObservation).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect {
        described_class.new.perform(account.id, 'import_target@example.com', 'follow', { 'follow_import_target_id' => import_target.id })
      }.not_to raise_error

      expect(follow_service).to have_received(:call)
    end
  end
end
