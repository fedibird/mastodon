# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupDirectory::Indexing do
  around do |example|
    previous = ENV['GROUP_DIRECTORY_INDEX']
    ENV['GROUP_DIRECTORY_INDEX'] = 'true'
    example.run
  ensure
    ENV['GROUP_DIRECTORY_INDEX'] = previous
  end

  before do
    allow(Chewy).to receive(:enabled?).and_return(true)
  end

  def reset_index_stubs
    RSpec::Mocks.space.proxy_for(described_class).reset
    allow(described_class).to receive(:enqueue)
    allow(described_class).to receive(:enqueue_domain)
  end

  def directory_group(username, domain: nil)
    local_user = domain.nil? ? Fabricate(:user, confirmed_at: 10.days.ago, approved: true) : nil
    account = Fabricate(:account, username: username, domain: domain, actor_type: 'Group', discoverable: true, user: local_user)
    account.create_account_stat!
    account
  end

  describe 'coalesced queue' do
    before do
      allow(GroupDirectoryIndexWorker).to receive(:perform_async)
    end

    it 'deduplicates ids and schedules one drain' do
      described_class.push([3, 3, 4])
      described_class.push([4, 5])

      expect(GroupDirectoryIndexWorker).to have_received(:perform_async).once
      expect(redis.smembers(described_class::PENDING_KEY)).to match_array(%w(3 4 5))
    end

    it 'waits for commit before pushing ids' do
      described_class.enqueue(12)

      expect(redis.smembers(described_class::PENDING_KEY)).to be_empty
      request = Account.connection.current_transaction.records.reverse.find { |record| record.is_a?(described_class::CommitRequest) }
      request.committed!(should_run_callbacks: true)

      expect(redis.smembers(described_class::PENDING_KEY)).to eq(['12'])
    end

    it 'drops ids when the commit request rolls back' do
      described_class.enqueue(13)
      request = Account.connection.current_transaction.records.reverse.find { |record| record.is_a?(described_class::CommitRequest) }
      request.rolledback!(should_run_callbacks: true)

      expect(redis.smembers(described_class::PENDING_KEY)).to be_empty
    end

    it 'does not push when live sync is off' do
      ENV['GROUP_DIRECTORY_INDEX'] = nil

      described_class.enqueue(14)
      described_class.push([14])

      expect(redis.smembers(described_class::PENDING_KEY)).to be_empty
      expect(GroupDirectoryIndexWorker).not_to have_received(:perform_async)
    end
  end

  describe GroupDirectoryIndexWorker do
    it 'imports the popped ids from the database id list' do
      allow(GroupDirectory::Indexing).to receive(:index_ready?).and_return(true)
      redis.sadd(GroupDirectory::Indexing::PENDING_KEY, %w(8 9))
      redis.set(GroupDirectory::Indexing::SCHEDULE_KEY, '1')
      allow(GroupDirectoryIndex).to receive(:import!)

      described_class.new.perform

      expect(GroupDirectoryIndex).to have_received(:import!) do |ids|
        expect(ids).to contain_exactly(8, 9)
      end
      expect(redis.get(GroupDirectory::Indexing::SCHEDULE_KEY)).to be_nil
      expect(redis.smembers(GroupDirectory::Indexing::PENDING_KEY)).to be_empty
    end

    it 'drains more than one batch' do
      allow(GroupDirectory::Indexing).to receive(:index_ready?).and_return(true)
      redis.sadd(GroupDirectory::Indexing::PENDING_KEY, (1..101).to_a)
      redis.set(GroupDirectory::Indexing::SCHEDULE_KEY, '1')
      imported = []
      allow(GroupDirectoryIndex).to receive(:import!) { |batch| imported.concat(batch) }

      described_class.new.perform

      expect(imported).to match_array((1..101).to_a)
    end

    it 'leaves pending ids in place when the index has not been created' do
      allow(GroupDirectory::Indexing).to receive(:index_ready?).and_return(false)
      redis.sadd(GroupDirectory::Indexing::PENDING_KEY, '4')
      redis.set(GroupDirectory::Indexing::SCHEDULE_KEY, '1')
      allow(GroupDirectoryIndex).to receive(:import!)

      described_class.new.perform

      expect(GroupDirectoryIndex).not_to have_received(:import!)
      expect(redis.smembers(GroupDirectory::Indexing::PENDING_KEY)).to eq(['4'])
      expect(redis.get(GroupDirectory::Indexing::SCHEDULE_KEY)).to be_nil
    end

    it 'puts a failed batch back and raises' do
      allow(GroupDirectory::Indexing).to receive(:index_ready?).and_return(true)
      redis.sadd(GroupDirectory::Indexing::PENDING_KEY, %w(8 9))
      redis.set(GroupDirectory::Indexing::SCHEDULE_KEY, '1')
      allow(GroupDirectoryIndex).to receive(:import!).and_raise(StandardError, 'bulk down')

      expect { described_class.new.perform }.to raise_error(StandardError, 'bulk down')
      expect(redis.smembers(GroupDirectory::Indexing::PENDING_KEY)).to match_array(%w(8 9))
    end

    it 'does not import when live sync is off' do
      ENV['GROUP_DIRECTORY_INDEX'] = nil
      redis.sadd(GroupDirectory::Indexing::PENDING_KEY, '4')
      redis.set(GroupDirectory::Indexing::SCHEDULE_KEY, '1')
      allow(GroupDirectoryIndex).to receive(:import!)

      described_class.new.perform

      expect(GroupDirectoryIndex).not_to have_received(:import!)
      expect(redis.smembers(GroupDirectory::Indexing::PENDING_KEY)).to eq(['4'])
    end
  end

  describe 'sync hooks' do
    before do
      allow(described_class).to receive(:enqueue)
      allow(described_class).to receive(:enqueue_domain)
    end

    it 'registers commit hooks and ignores accounts that are not groups' do
      expect(Account._commit_callbacks.map(&:filter)).to include(:request_group_directory_index)
      expect(AccountStat._commit_callbacks.map(&:filter)).to include(:request_group_directory_index)
      expect(GroupLanguage._commit_callbacks.map(&:filter)).to include(:request_group_directory_index)
      expect(Node._commit_callbacks.map(&:filter)).to include(:request_group_directory_index)
      expect(User._commit_callbacks.map(&:filter)).to include(:request_group_directory_index)
      expect(ManagedGroup._commit_callbacks.map(&:filter)).to include(:request_group_directory_index)

      person = Fabricate(:account, username: 'not_a_group', display_name: 'Ada')
      person.update!(display_name: 'Ada Lovelace')
      person.send(:request_group_directory_index)
      person.increment_count!(:statuses_count)

      expect(described_class).not_to have_received(:enqueue)
    end

    it 'enqueues on profile, suspension, actor type, activity, approval, and a raw status count' do
      group = directory_group('sync_group')
      reset_index_stubs

      group.update!(display_name: 'Renamed', note: '<p>next</p>')
      group.update!(suspended_at: Time.now.utc)
      group.account_stat.update!(last_status_at: Time.now.utc)
      group.increment_count!(:followers_count)
      group.increment_count!(:statuses_count)
      group.user.update!(current_sign_in_at: Time.now.utc)
      group.user.update!(approved: false)

      expect(described_class).to have_received(:enqueue).with(group.id).exactly(5).times

      group.update!(actor_type: 'Person')
      expect(described_class).to have_received(:enqueue).with(group.id).exactly(6).times
    end

    it 'enqueues after language replacement, including a delete_all that clears every tag' do
      group = directory_group('lang_sync')
      reset_index_stubs
      allow(GroupDirectory::Languages).to receive(:allowed?).and_return(true)

      # The new row's commit hook and replace! both enqueue. The set dedups them.
      GroupDirectory::Languages.replace!(account: group, tags: ['JA'], actor: group)
      expect(group.group_languages.pluck(:tag)).to eq(['ja'])
      expect(described_class).to have_received(:enqueue).with(group.id).twice

      # delete_all skips the row hook, so the explicit enqueue is the one that remains.
      GroupDirectory::Languages.replace!(account: group, tags: [], actor: group)
      expect(group.group_languages).to be_empty
      expect(described_class).to have_received(:enqueue).with(group.id).exactly(3).times
    end

    it 'enqueues a domain when NodeInfo software or presence changes, and skips a user-count rewrite' do
      Node.create!(domain: 'sync.example', info: { 'software_name' => 'lemmy', 'total_users' => 1 }, nodeinfo: { 'ok' => true })
      group = directory_group('remote_sync', domain: 'sync.example')
      person = Fabricate(:account, username: 'remote_person', domain: 'sync.example')
      node = Node.find_by!(domain: 'sync.example')

      expect(described_class).to have_received(:enqueue_domain).with('sync.example').once

      node.update!(info: { 'software_name' => 'lemmy', 'total_users' => 4 })
      expect(described_class).to have_received(:enqueue_domain).with('sync.example').once

      node.update!(last_fetched_at: Time.now.utc)
      expect(described_class).to have_received(:enqueue_domain).with('sync.example').once

      node.update!(info: { 'software_name' => 'piefed', 'total_users' => 4 })
      expect(described_class).to have_received(:enqueue_domain).with('sync.example').twice

      allow(described_class).to receive(:enqueue_domain).and_call_original
      described_class.enqueue_domain('sync.example')
      expect(described_class).to have_received(:enqueue).with([group.id])
      expect(described_class).not_to have_received(:enqueue).with(a_collection_including(person.id))
    end

    it 'skips a brand new group that is not listable yet' do
      group = directory_group('fresh_group', domain: nil)
      group.update!(discoverable: false)
      reset_index_stubs
      allow(group).to receive(:previously_new_record?).and_return(true)

      group.send(:request_group_directory_index)

      expect(described_class).not_to have_received(:enqueue)
    end
  end
end
