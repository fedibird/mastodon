# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupDirectory::LiveIndex do
  let(:real_name) { 'group_directory_test' }

  def client_for(*names)
    deleted = []
    existing = names.dup
    indices = Object.new
    indices.define_singleton_method(:exists?) { |index:| existing.include?(index) }
    indices.define_singleton_method(:delete) do |index:|
      deleted << index
      existing.delete(index)
    end
    indices.define_singleton_method(:deleted) { deleted }
    client = Object.new
    client.define_singleton_method(:indices) { indices }
    client
  end

  it 'names a temporary index and refuses to delete the configured one' do
    name = described_class.temporary_name(real_name)

    expect(name).to start_with(described_class::PREFIX)
    expect(name).not_to eq(real_name)

    client = client_for(real_name, name)
    expect { described_class.delete_temporary!(client, real_name, real_name) }.to raise_error(described_class::UnsafeIndex)
    expect(client.indices.deleted).to be_empty

    described_class.delete_temporary!(client, name, real_name)
    expect(client.indices.deleted).to eq([name])
    expect(client.indices.exists?(index: real_name)).to be true
  end

  it 'does not delete an index from the live example' do
    source = File.read(Rails.root.join('spec/services/group_directory/elasticsearch_live_spec.rb'))

    expect(source).not_to match(/purge/i)
    expect(source).to include('Refusing to touch it')
    expect(source).to include('delete_temporary!')
  end
end
