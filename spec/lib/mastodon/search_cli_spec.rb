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

      invoke(min: '0', max: '0')

      expect(Chewy::Index::Import::BulkRequest).to have_received(:new).with(InstancesIndex)
    end
  end
end
