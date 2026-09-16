require 'rails_helper'

RSpec.describe ImportService, type: :service do
  include RoutingHelper

  let!(:account) { Fabricate(:account, locked: false) }
  let!(:bob)     { Fabricate(:account, username: 'bob', locked: false) }
  let!(:eve)     { Fabricate(:account, username: 'eve', domain: 'example.com', locked: false, protocol: :activitypub, inbox_url: 'https://example.com/inbox') }

  before do
    stub_request(:post, "https://example.com/inbox").to_return(status: 200)
  end

  context 'import old-style list of muted users' do
    subject { ImportService.new }

    let(:csv) { attachment_fixture('mute-imports.txt') }

    describe 'when no accounts are muted' do
      let(:import) { Import.create(account: account, type: 'muting', data: csv) }
      it 'mutes the listed accounts, including notifications' do
        subject.call(import)
        expect(account.muting.count).to eq 2
        expect(Mute.find_by(account: account, target_account: bob).hide_notifications).to be true
      end
    end

    describe 'when some accounts are muted and overwrite is not set' do
      let(:import) { Import.create(account: account, type: 'muting', data: csv) }

      it 'mutes the listed accounts, including notifications' do
        account.mute!(bob, notifications: false)
        subject.call(import)
        expect(account.muting.count).to eq 2
        expect(Mute.find_by(account: account, target_account: bob).hide_notifications).to be true
      end
    end

    describe 'when some accounts are muted and overwrite is set' do
      let(:import) { Import.create(account: account, type: 'muting', data: csv, overwrite: true) }

      it 'mutes the listed accounts, including notifications' do
        account.mute!(bob, notifications: false)
        subject.call(import)
        expect(account.muting.count).to eq 2
        expect(Mute.find_by(account: account, target_account: bob).hide_notifications).to be true
      end
    end
  end

  context 'import new-style list of muted users' do
    subject { ImportService.new }

    let(:csv) { attachment_fixture('new-mute-imports.txt') }

    describe 'when no accounts are muted' do
      let(:import) { Import.create(account: account, type: 'muting', data: csv) }
      it 'mutes the listed accounts, respecting notifications' do
        subject.call(import)
        expect(account.muting.count).to eq 2
        expect(Mute.find_by(account: account, target_account: bob).hide_notifications).to be true
        expect(Mute.find_by(account: account, target_account: eve).hide_notifications).to be false
      end
    end

    describe 'when some accounts are muted and overwrite is not set' do
      let(:import) { Import.create(account: account, type: 'muting', data: csv) }

      it 'mutes the listed accounts, respecting notifications' do
        account.mute!(bob, notifications: true)
        subject.call(import)
        expect(account.muting.count).to eq 2
        expect(Mute.find_by(account: account, target_account: bob).hide_notifications).to be true
        expect(Mute.find_by(account: account, target_account: eve).hide_notifications).to be false
      end
    end

    describe 'when some accounts are muted and overwrite is set' do
      let(:import) { Import.create(account: account, type: 'muting', data: csv, overwrite: true) }

      it 'mutes the listed accounts, respecting notifications' do
        account.mute!(bob, notifications: true)
        subject.call(import)
        expect(account.muting.count).to eq 2
        expect(Mute.find_by(account: account, target_account: bob).hide_notifications).to be true
        expect(Mute.find_by(account: account, target_account: eve).hide_notifications).to be false
      end
    end
  end

  context 'import old-style list of followed users' do
    subject { ImportService.new }

    let(:csv) { attachment_fixture('mute-imports.txt') }

    describe 'when no accounts are followed' do
      let(:import) { Import.create(account: account, type: 'following', data: csv) }
      it 'follows the listed accounts, including boosts' do
        subject.call(import)

        expect(account.following.count).to eq 1
        expect(account.follow_requests.count).to eq 1
        expect(Follow.find_by(account: account, target_account: bob).show_reblogs).to be true
      end
    end

    describe 'when some accounts are already followed and overwrite is not set' do
      let(:import) { Import.create(account: account, type: 'following', data: csv) }

      it 'follows the listed accounts, including notifications' do
        account.follow!(bob, reblogs: false)
        subject.call(import)
        expect(account.following.count).to eq 1
        expect(account.follow_requests.count).to eq 1
        expect(Follow.find_by(account: account, target_account: bob).show_reblogs).to be true
      end
    end

    describe 'when some accounts are already followed and overwrite is set' do
      let(:import) { Import.create(account: account, type: 'following', data: csv, overwrite: true) }

      it 'mutes the listed accounts, including notifications' do
        account.follow!(bob, reblogs: false)
        subject.call(import)
        expect(account.following.count).to eq 1
        expect(account.follow_requests.count).to eq 1
        expect(Follow.find_by(account: account, target_account: bob).show_reblogs).to be true
      end
    end
  end

  context 'import new-style list of followed users' do
    subject { ImportService.new }

    let(:csv) { attachment_fixture('new-following-imports.txt') }

    describe 'when no accounts are followed' do
      let(:import) { Import.create(account: account, type: 'following', data: csv) }
      it 'follows the listed accounts, respecting boosts' do
        subject.call(import)
        expect(account.following.count).to eq 1
        expect(account.follow_requests.count).to eq 1
        expect(Follow.find_by(account: account, target_account: bob).show_reblogs).to be true
        expect(FollowRequest.find_by(account: account, target_account: eve).show_reblogs).to be false
      end
    end

    describe 'when some accounts are already followed and overwrite is not set' do
      let(:import) { Import.create(account: account, type: 'following', data: csv) }

      it 'mutes the listed accounts, respecting notifications' do
        account.follow!(bob, reblogs: true)
        subject.call(import)
        expect(account.following.count).to eq 1
        expect(account.follow_requests.count).to eq 1
        expect(Follow.find_by(account: account, target_account: bob).show_reblogs).to be true
        expect(FollowRequest.find_by(account: account, target_account: eve).show_reblogs).to be false
      end
    end

    describe 'when some accounts are already followed and overwrite is set' do
      let(:import) { Import.create(account: account, type: 'following', data: csv, overwrite: true) }

      it 'mutes the listed accounts, respecting notifications' do
        account.follow!(bob, reblogs: true)
        subject.call(import)
        expect(account.following.count).to eq 1
        expect(account.follow_requests.count).to eq 1
        expect(Follow.find_by(account: account, target_account: bob).show_reblogs).to be true
        expect(FollowRequest.find_by(account: account, target_account: eve).show_reblogs).to be false
      end
    end
  end

  context 'import bookmarks' do
    subject { ImportService.new }

    let(:csv) { attachment_fixture('bookmark-imports.txt') }

    around(:each) do |example|
      local_before = Rails.configuration.x.local_domain
      web_before = Rails.configuration.x.web_domain
      Rails.configuration.x.local_domain = 'local.com'
      Rails.configuration.x.web_domain = 'local.com'
      example.run
      Rails.configuration.x.web_domain = web_before
      Rails.configuration.x.local_domain = local_before
    end

    let(:local_account)  { Fabricate(:account, username: 'foo', domain: '') }
    let!(:remote_status) { Fabricate(:status, uri: 'https://example.com/statuses/1312') }
    let!(:direct_status) { Fabricate(:status, uri: 'https://example.com/statuses/direct', visibility: :direct) }

    before do
      service = double
      allow(ActivityPub::FetchRemoteStatusService).to receive(:new).and_return(service)
      allow(service).to receive(:call).with('https://unknown-remote.com/users/bar/statuses/1') do
        Fabricate(:status, uri: 'https://unknown-remote.com/users/bar/statuses/1')
      end
    end

    describe 'when no bookmarks are set' do
      let(:import) { Import.create(account: account, type: 'bookmarks', data: csv) }
      it 'adds the toots the user has access to to bookmarks' do
        local_status = Fabricate(:status, account: local_account, uri: 'https://local.com/users/foo/statuses/42', id: 42, local: true)
        subject.call(import)
        expect(account.bookmarks.map(&:status).map(&:id)).to include(local_status.id)
        expect(account.bookmarks.map(&:status).map(&:id)).to include(remote_status.id)
        expect(account.bookmarks.map(&:status).map(&:id)).not_to include(direct_status.id)
        expect(account.bookmarks.count).to eq 3
      end
    end
  end

  # Follow imports no longer bulk-enqueue every follow at ImportService time.
  # They record the batch and hand execution to the DB-backed batch executor,
  # which claims/paces the targets. These specs assert that handoff at the
  # ImportService boundary; the executor -> RelationshipWorker -> FollowService
  # -> ledger legs are covered in batch_execution_worker_spec,
  # relationship_worker_spec, and interaction_hooks_spec.
  context 'follow-import controlled execution' do
    subject { ImportService.new }

    let(:csv_text) { "Account address,Show boosts\nbob,true\neve@example.com,false" }
    let(:import)   { Import.create(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt')) }

    before do
      allow_any_instance_of(described_class).to receive(:import_data).and_return(csv_text)
    end

    def create_owned_batch(import_record, dispatch_owner:)
      FollowImportBatch.create!(
        subject: ModerationSubject.for_account!(account),
        import_id: import_record.id,
        imported_at: Time.now.utc,
        mode: :merge,
        dispatch_owner: dispatch_owner,
        target_count: 0,
        resolved_target_count: 0,
        unresolved_target_count: 0
      )
    end

    it 'records the batch and hands the follow set to the batch executor instead of a bulk enqueue' do
      allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
      expect(Import::RelationshipWorker).not_to receive(:push_bulk)

      subject.call(import)

      batch = FollowImportBatch.find_by(import_id: import.id)
      expect(batch).to be_present
      expect(batch.legacy_dispatch_owner?).to be true
      # One target per execution unit (bob local + eve remote).
      expect(batch.targets.count).to eq 2
      expect(FollowImport::BatchExecutionWorker).to have_received(:perform_async).with(batch.id)
    end

    it 'creates a scheduler-owned batch and does not enqueue BatchExecutionWorker when GLOBAL is on' do
      allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
      allow(Import::RelationshipWorker).to receive(:push_bulk)
      allow(Import::RelationshipWorker).to receive(:perform_async)

      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_GLOBAL: 'true' do
        subject.call(import)
      end

      batch = FollowImportBatch.find_by(import_id: import.id)
      expect(batch).to be_present
      expect(batch.scheduler_dispatch_owner?).to be true
      expect(batch.targets.where(state: :pending).count).to eq 2
      expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
      expect(Import::RelationshipWorker).not_to have_received(:push_bulk)
    end

    it 'follows stored ownership on retry after GLOBAL flips on' do
      allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
      subject.call(import)
      batch = FollowImportBatch.find_by(import_id: import.id)
      expect(batch.legacy_dispatch_owner?).to be true
      expect(FollowImport::BatchExecutionWorker).to have_received(:perform_async).with(batch.id)

      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_GLOBAL: 'true' do
        subject.call(import)
      end

      expect(batch.reload.legacy_dispatch_owner?).to be true
      expect(FollowImport::BatchExecutionWorker).to have_received(:perform_async).with(batch.id).twice
    end

    it 'keeps a scheduler-owned batch on the scheduler after GLOBAL flips off' do
      allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
      allow(Import::RelationshipWorker).to receive(:push_bulk)

      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_GLOBAL: 'true' do
        subject.call(import)
      end
      batch = FollowImportBatch.find_by(import_id: import.id)
      expect(batch.scheduler_dispatch_owner?).to be true

      subject.call(import)

      expect(batch.reload.scheduler_dispatch_owner?).to be true
      expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
    end

    it 'raises and does not bulk-enqueue follows when GLOBAL recording fails' do
      allow(Moderation::FollowImportRecorder).to receive(:record_batch!).and_raise(ActiveRecord::StatementInvalid, 'boom')
      allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
      allow(Import::RelationshipWorker).to receive(:push_bulk)
      allow(Import::RelationshipWorker).to receive(:perform_async)

      ClimateControl.modify FOLLOW_IMPORT_DISPATCH_GLOBAL: 'true' do
        expect { subject.call(import) }.to raise_error(ActiveRecord::StatementInvalid, 'boom')
      end

      expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
      expect(Import::RelationshipWorker).not_to have_received(:push_bulk)
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
      expect(Import.exists?(import.id)).to be true
    end

    it 'unfollows current follows absent from the import when overwriting' do
      other = Fabricate(:account, username: 'carol')
      account.follow!(other)

      allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
      captured = []
      allow(Import::RelationshipWorker).to receive(:perform_async) { |*args| captured << args }

      import.update!(overwrite: true)
      subject.call(import)

      unfollows = captured.select { |args| args[2] == 'unfollow' }
      expect(unfollows.map { |args| args[1] }).to include('carol')
    end

    it 'falls back to a direct bulk enqueue when batch recording failed, without ledger linkage' do
      allow(Moderation::FollowImportRecorder).to receive(:record_batch).and_return(nil)
      allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)

      pushed = []
      allow(Import::RelationshipWorker).to receive(:push_bulk) do |items, &block|
        items.each { |item| pushed << block.call(item) }
      end

      expect { subject.call(import) }.to_not raise_error

      expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
      follow_args = pushed.select { |args| args[2] == 'follow' }
      expect(follow_args).to be_present
      follow_args.each { |args| expect(args[3]).to_not have_key('import_batch_id') }
    end

    it 'does not use the direct fallback for a stored scheduler-owned batch when GLOBAL is later off' do
      batch = create_owned_batch(import, dispatch_owner: :scheduler)
      allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
      allow(Import::RelationshipWorker).to receive(:push_bulk)
      allow(Import::RelationshipWorker).to receive(:perform_async)
      allow(Moderation::FollowImportRecorder).to receive(:record_batch).and_return(nil)

      subject.call(import)

      expect(batch.reload.scheduler_dispatch_owner?).to be true
      expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
      expect(Import::RelationshipWorker).not_to have_received(:push_bulk)
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    end

    it 'raises and does not enqueue follows when the durable-batch lookup fails' do
      allow(FollowImportBatch).to receive(:find_by).and_wrap_original do |method, *args|
        attrs = args.first
        raise ActiveRecord::StatementInvalid, 'lookup down' if attrs.is_a?(Hash) && attrs[:import_id] == import.id

        method.call(*args)
      end
      allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
      allow(Import::RelationshipWorker).to receive(:push_bulk)
      allow(Import::RelationshipWorker).to receive(:perform_async)
      allow(Moderation::FollowImportRecorder).to receive(:record_batch)

      expect { subject.call(import) }.to raise_error(ActiveRecord::StatementInvalid, 'lookup down')

      expect(Moderation::FollowImportRecorder).not_to have_received(:record_batch)
      expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
      expect(Import::RelationshipWorker).not_to have_received(:push_bulk)
      expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    end

    it 'uses a concurrently visible durable batch after tolerant recording returns nil' do
      batch = create_owned_batch(import, dispatch_owner: :scheduler)
      lookups = 0
      allow(FollowImportBatch).to receive(:find_by).and_wrap_original do |method, *args|
        attrs = args.first
        if attrs.is_a?(Hash) && attrs[:import_id] == import.id
          lookups += 1
          lookups == 1 ? nil : method.call(*args)
        else
          method.call(*args)
        end
      end
      allow(Moderation::FollowImportRecorder).to receive(:record_batch).and_return(nil)
      allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)
      allow(Import::RelationshipWorker).to receive(:push_bulk)
      allow(Import::RelationshipWorker).to receive(:perform_async)

      subject.call(import)

      expect(lookups).to be >= 2
      expect(batch.reload.scheduler_dispatch_owner?).to be true
      expect(FollowImport::BatchExecutionWorker).not_to have_received(:perform_async)
      expect(Import::RelationshipWorker).not_to have_received(:push_bulk)
    end
  end
end
