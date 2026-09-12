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

  # Assert the follow-import -> batch-id propagation at ImportService's enqueue
  # boundary, capturing the worker args it produces. This avoids executing the
  # follows inline (that path renders a notification mailer needing a webpack
  # manifest not built in the test env) and does not depend on Sidekiq's queue
  # internals. The worker -> FollowService -> ledger legs are covered in
  # relationship_worker_spec and interaction_hooks_spec.
  context 'follow-import moderation ledger linkage' do
    subject { ImportService.new }

    # Inline CSV (no trailing blank row) so the generic import_relationships!
    # loop enqueues both targets; a trailing blank row trips its existing
    # `return if key.blank?` guard, which is unrelated to this change.
    let(:csv_text) { "Account address,Show boosts\nbob,true\neve@example.com,false" }
    let(:import)   { Import.create(account: account, type: 'following', data: attachment_fixture('new-following-imports.txt')) }

    # Capture every relationship-worker enqueue (both perform_async and the
    # push_bulk block form) as plain args arrays.
    def capture_enqueues!
      captured = []
      allow(Import::RelationshipWorker).to receive(:perform_async) { |*args| captured << args }
      allow(Import::RelationshipWorker).to receive(:push_bulk) do |items, &block|
        items.each { |item| captured << block.call(item) }
      end
      captured
    end

    before do
      allow_any_instance_of(described_class).to receive(:import_data).and_return(csv_text)
    end

    it 'stamps the FollowImportBatch id onto every follow it enqueues' do
      captured = capture_enqueues!

      subject.call(import)

      batch = FollowImportBatch.find_by(import_id: import.id)
      expect(batch).to be_present

      follow_args = captured.select { |args| args[2] == 'follow' }
      # bob (local) and eve (remote) are both followed by this import.
      expect(follow_args.size).to eq 2
      expect(follow_args.map { |args| args[3]['import_batch_id'] }.uniq).to eq [batch.id]
    end

    it 'omits import_batch_id from the enqueued follows when batch recording failed, without raising' do
      allow(Moderation::FollowImportRecorder).to receive(:record_batch).and_return(nil)
      captured = capture_enqueues!

      expect { subject.call(import) }.to_not raise_error

      follow_args = captured.select { |args| args[2] == 'follow' }
      expect(follow_args).to be_present
      follow_args.each { |args| expect(args[3]).to_not have_key('import_batch_id') }
    end
  end
end
