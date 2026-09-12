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
end
