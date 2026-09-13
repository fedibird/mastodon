# frozen_string_literal: true

require 'rails_helper'

# Local follow-import targets have no remote delivery round-trip, so their
# execution state must be settled locally (otherwise, now that the target set is
# the source of truth, they would sit non-terminal forever and a batch could
# never reach completed).
RSpec.describe 'Local follow-import target execution', type: :service do
  let(:source)   { Fabricate(:account) }
  let(:unlocked) { Fabricate(:account, username: 'localunlocked') }
  let(:locked)   { Fabricate(:account, username: 'locallocked', locked: true) }

  let(:batch) do
    FollowImportBatch.create!(subject: ModerationSubject.for_account!(source), imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  def target_for(account, position)
    batch.targets.create!(target_subject: ModerationSubject.for_account!(account), position: position)
  end

  before do
    # Isolate follow execution from notification side effects (unrelated here and
    # dependent on a webpack manifest not built in the test env).
    allow(NotifyService).to receive(:new).and_return(instance_double(NotifyService, call: nil))
    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(MergeWorker).to receive(:perform_async)
  end

  describe 'an unlocked local target' do
    it 'reaches accepted immediately when direct_follow! succeeds' do
      target = target_for(unlocked, 0)

      FollowService.new.call(source, unlocked, import_batch_id: batch.id, follow_import_target_id: target.id)

      expect(source.following?(unlocked)).to be true
      expect(target.reload.state).to eq 'accepted'
    end
  end

  describe 'a locked local target' do
    it 'waits for the recipient decision (awaiting_response) with a correlation uri' do
      target = target_for(locked, 0)

      FollowService.new.call(source, locked, import_batch_id: batch.id, follow_import_target_id: target.id)

      follow_request = FollowRequest.find_by(account: source, target_account: locked)
      expect(source.requested?(locked)).to be true
      target.reload
      expect(target.state).to eq 'awaiting_response'
      expect(target.follow_request_uri).to eq follow_request.uri
    end

    it 'becomes accepted when the local recipient approves the request' do
      target = target_for(locked, 0)
      FollowService.new.call(source, locked, import_batch_id: batch.id, follow_import_target_id: target.id)

      AuthorizeFollowService.new.call(source, locked)

      expect(source.following?(locked)).to be true
      expect(target.reload.state).to eq 'accepted'
    end

    it 'becomes rejected when the local recipient rejects the request' do
      target = target_for(locked, 0)
      FollowService.new.call(source, locked, import_batch_id: batch.id, follow_import_target_id: target.id)

      RejectFollowService.new.call(source, locked)

      expect(source.requested?(locked)).to be false
      expect(target.reload.state).to eq 'rejected'
    end
  end
end
