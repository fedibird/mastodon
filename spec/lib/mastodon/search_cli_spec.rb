# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/mastodon/search_cli')

describe Mastodon::SearchCLI do
  def invoke(options = {})
    cli = described_class.new
    stdout = $stdout
    $stdout = StringIO.new
    cli.invoke(:deploy, [], { concurrency: 1 }.merge(options))
  ensure
    $stdout = stdout
  end

  def stub_index_specification(*indices)
    specification = instance_double(Chewy::Index::Specification, changed?: false)
    indices.each do |index|
      allow(index).to receive(:specification).and_return(specification)
    end
  end

  before do
    allow(Chewy::Index::Import::BulkRequest).to receive(:new).and_return(double(perform: nil))
  end

  describe '#deploy' do
    def stub_instances_batch
      record = Instance.new(domain: 'peers.example', accounts_count: 4)
      scope = double('instances scope')
      allow(scope).to receive(:count).and_return(1)
      allow(scope).to receive(:reorder).with(nil).and_return(scope)
      allow(scope).to receive(:find_in_batches).and_yield([record])
      allow(InstancesIndex.adapter).to receive(:default_scope).and_return(scope)
      record
    end

    it 'imports InstancesIndex by domain when --only instances is set' do
      stub_index_specification(InstancesIndex)
      stub_instances_batch

      expect { invoke(only: ['instances'], min: '1', max: '2') }.not_to raise_error

      expect(Chewy::Index::Import::BulkRequest).to have_received(:new).with(InstancesIndex)
    end

    it 'leaves InstancesIndex alone when --only accounts is set' do
      stub_index_specification(AccountsIndex)

      invoke(only: ['accounts'], min: '0', max: '0')

      expect(Chewy::Index::Import::BulkRequest).not_to have_received(:new).with(InstancesIndex)
    end

    it 'includes InstancesIndex in a full deploy' do
      stub_instances_batch
      stub_index_specification(InstancesIndex, AccountsIndex, TagsIndex, StatusesIndex)
      expect(GroupDirectoryIndex).not_to receive(:specification)
      expect(GroupDirectoryIndex).not_to receive(:purge)

      invoke(min: '0', max: '0')

      expect(Chewy::Index::Import::BulkRequest).to have_received(:new).with(InstancesIndex)
    end

    it 'imports only GroupDirectoryIndex when --only group_directory is set' do
      stub_index_specification(GroupDirectoryIndex)
      record = Account.new(id: 15, username: 'directory', actor_type: 'Group', created_at: Time.now.utc, updated_at: Time.now.utc)
      scope = double('group directory scope', count: 1)
      allow(scope).to receive(:where).and_return(scope)
      allow(scope).to receive(:reorder).with(nil).and_return(scope)
      allow(scope).to receive(:find_in_batches).and_yield([record])
      allow(GroupDirectoryIndex.adapter).to receive(:default_scope).and_return(scope)
      allow(GroupDirectory::Import).to receive(:call).and_return(GroupDirectory::Import::Result.new(indexed: 1, deleted: 0, rejected: 0))
      expect(AccountsIndex).not_to receive(:purge)
      expect(StatusesIndex).not_to receive(:purge)

      invoke(only: ['group_directory'])

      expect(GroupDirectory::Import).to have_received(:call).with([15])
      expect(Chewy::Index::Import::BulkRequest).not_to have_received(:new).with(GroupDirectoryIndex)
      expect(Chewy::Index::Import::BulkRequest).not_to have_received(:new).with(AccountsIndex)
      expect(Chewy::Index::Import::BulkRequest).not_to have_received(:new).with(StatusesIndex)
    end

    it 'exits with a failure when a group directory batch raises' do
      stub_index_specification(GroupDirectoryIndex)
      record = Account.new(id: 15, username: 'directory', actor_type: 'Group', created_at: Time.now.utc, updated_at: Time.now.utc)
      scope = double('group directory scope', count: 1)
      allow(scope).to receive(:where).and_return(scope)
      allow(scope).to receive(:reorder).with(nil).and_return(scope)
      allow(scope).to receive(:find_in_batches).and_yield([record])
      allow(GroupDirectoryIndex.adapter).to receive(:default_scope).and_return(scope)
      allow(GroupDirectory::Import).to receive(:call).and_raise(StandardError, 'bulk down')

      expect { invoke(only: ['group_directory']) }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end

    it 'rebuilds only the group directory index' do
      allow(GroupDirectory::Import).to receive(:rebuild!)
      expect(AccountsIndex).not_to receive(:purge)

      invoke(only: ['group_directory'], rebuild: true)

      expect(GroupDirectory::Import).to have_received(:rebuild!)
    end

    it 'refuses to rebuild any index other than group_directory' do
      expect(GroupDirectory::Import).not_to receive(:rebuild!)

      expect { invoke(only: ['accounts'], rebuild: true) }.to raise_error(SystemExit)
    end

    it 'purges only GroupDirectoryIndex when its mapping changed' do
      specification = instance_double(Chewy::Index::Specification, changed?: true)
      allow(GroupDirectoryIndex).to receive(:specification).and_return(specification)
      allow(GroupDirectoryIndex).to receive(:purge)
      allow(specification).to receive(:lock!)
      scope = double('empty group directory scope', count: 0)
      allow(scope).to receive(:where).and_return(scope)
      allow(scope).to receive(:reorder).with(nil).and_return(scope)
      allow(scope).to receive(:find_in_batches)
      allow(GroupDirectoryIndex.adapter).to receive(:default_scope).and_return(scope)
      expect(AccountsIndex).not_to receive(:purge)

      invoke(only: ['group_directory'])

      expect(GroupDirectoryIndex).to have_received(:purge)
      expect(specification).to have_received(:lock!)
    end

    it 'drops the backfill marker before a mapping purge and restores it only after success' do
      specification = instance_double(Chewy::Index::Specification, changed?: true)
      allow(GroupDirectoryIndex).to receive(:specification).and_return(specification)
      allow(GroupDirectoryIndex).to receive(:purge)
      allow(specification).to receive(:lock!)
      scope = double('empty group directory scope', count: 0)
      allow(scope).to receive(:where).and_return(scope)
      allow(scope).to receive(:reorder).with(nil).and_return(scope)
      allow(scope).to receive(:find_in_batches)
      allow(GroupDirectoryIndex.adapter).to receive(:default_scope).and_return(scope)
      GroupDirectory::Indexing.mark_backfill_complete!

      invoke(only: ['group_directory'])

      expect(GroupDirectory::Indexing.backfill_complete?).to be true
    end

    it 'does not mark the directory ready when a mapping upgrade is limited by id' do
      specification = instance_double(Chewy::Index::Specification, changed?: true)
      allow(GroupDirectoryIndex).to receive(:specification).and_return(specification)
      allow(GroupDirectoryIndex).to receive(:purge)
      allow(specification).to receive(:lock!)
      scope = double('bounded group directory scope', count: 0)
      allow(scope).to receive(:where).and_return(scope)
      allow(scope).to receive(:reorder).with(nil).and_return(scope)
      allow(scope).to receive(:find_in_batches)
      allow(GroupDirectoryIndex.adapter).to receive(:default_scope).and_return(scope)
      GroupDirectory::Indexing.mark_backfill_complete!

      invoke(only: ['group_directory'], min: '0', max: '0')

      expect(GroupDirectoryIndex).to have_received(:purge)
      expect(GroupDirectory::Indexing.backfill_complete?).to be false
    end

    it 'leaves the backfill marker clear when a purged directory import fails' do
      specification = instance_double(Chewy::Index::Specification, changed?: true)
      allow(GroupDirectoryIndex).to receive(:specification).and_return(specification)
      allow(GroupDirectoryIndex).to receive(:purge)
      allow(specification).to receive(:lock!)
      record = Account.new(id: 15, username: 'directory', actor_type: 'Group', created_at: Time.now.utc, updated_at: Time.now.utc)
      scope = double('group directory scope', count: 1)
      allow(scope).to receive(:where).and_return(scope)
      allow(scope).to receive(:reorder).with(nil).and_return(scope)
      allow(scope).to receive(:find_in_batches).and_yield([record])
      allow(GroupDirectoryIndex.adapter).to receive(:default_scope).and_return(scope)
      allow(GroupDirectory::Import).to receive(:call).and_raise(StandardError, 'bulk down')
      GroupDirectory::Indexing.mark_backfill_complete!

      expect { invoke(only: ['group_directory']) }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(GroupDirectoryIndex).to have_received(:purge)
      expect(GroupDirectory::Indexing.backfill_complete?).to be false
    end
  end
end
