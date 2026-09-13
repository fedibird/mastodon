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
      t = batch.targets.create!(target_key_hash: 'unresolvable-key', position: 0)
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
  end
end
