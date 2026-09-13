# frozen_string_literal: true

require 'rails_helper'

# When a follow import targets an account the importer is ALREADY following (or
# has already requested), FollowService#call returns early via
# change_follow_options! / change_follow_request_options!, bypassing both local
# settlement and remote delivery tracking. The batch executor has already claimed
# the target to queued, so it must still be settled on these early-return paths.
RSpec.describe 'Existing-relationship follow-import target settlement', type: :service do
  let(:source) { Fabricate(:account) }

  let(:local_target)  { Fabricate(:account, username: 'localfriend') }
  let(:remote_target) do
    Fabricate(:account, domain: 'example.com', uri: 'https://example.com/users/bob',
                        inbox_url: 'https://example.com/inbox', protocol: :activitypub)
  end

  let(:batch) do
    FollowImportBatch.create!(subject: ModerationSubject.for_account!(source), imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  def claimed_target_for(account, position)
    target = batch.targets.create!(target_subject: ModerationSubject.for_account!(account), position: position)
    FollowImport::TargetTransitionService.new.mark_queued(target) # executor already claimed it
    target
  end

  before do
    # Isolate from notification/merge side effects.
    allow(NotifyService).to receive(:new).and_return(instance_double(NotifyService, call: nil))
    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(MergeWorker).to receive(:perform_async)
    allow(UnmergeWorker).to receive(:perform_async)
    stub_request(:post, 'https://example.com/inbox').to_return(status: 200)
  end

  shared_examples 'settles an already-followed target to accepted' do |target_method|
    it 'marks the claimed target accepted' do
      target_account = public_send(target_method)
      target = claimed_target_for(target_account, 0)
      source.follow!(target_account)

      FollowService.new.call(source, target_account, import_batch_id: batch.id, follow_import_target_id: target.id)

      expect(target.reload.state).to eq 'accepted'
    end
  end

  shared_examples 'settles an already-requested target to awaiting_response' do |target_method|
    it 'marks the claimed target awaiting_response and persists the existing request uri' do
      target_account = public_send(target_method)
      target = claimed_target_for(target_account, 0)
      request = source.request_follow!(target_account)

      FollowService.new.call(source, target_account, import_batch_id: batch.id, follow_import_target_id: target.id)

      target.reload
      expect(target.state).to eq 'awaiting_response'
      expect(target.follow_request_uri).to eq request.uri
    end
  end

  describe 'local target' do
    include_examples 'settles an already-followed target to accepted', :local_target
    include_examples 'settles an already-requested target to awaiting_response', :local_target

    it 'correlates a later local approval of an already-requested target' do
      target = claimed_target_for(local_target, 0)
      source.request_follow!(local_target)
      FollowService.new.call(source, local_target, import_batch_id: batch.id, follow_import_target_id: target.id)

      AuthorizeFollowService.new.call(source, local_target)

      expect(target.reload.state).to eq 'accepted'
    end
  end

  describe 'remote target' do
    include_examples 'settles an already-followed target to accepted', :remote_target
    include_examples 'settles an already-requested target to awaiting_response', :remote_target
  end
end
