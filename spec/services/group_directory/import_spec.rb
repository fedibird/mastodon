# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupDirectory::Import do
  around do |example|
    previous = ENV['GROUP_DIRECTORY_INDEX']
    ENV['GROUP_DIRECTORY_INDEX'] = 'true'
    example.run
  ensure
    ENV['GROUP_DIRECTORY_INDEX'] = previous
  end

  before do
    allow(Chewy).to receive(:enabled?).and_return(true)
    allow(GroupDirectoryIndexWorker).to receive(:perform_async)
  end

  def directory_group(username)
    user = Fabricate(:user, confirmed_at: 10.days.ago, approved: true)
    account = Fabricate(:account, username: username, actor_type: 'Group', discoverable: true, display_name: username, user: user)
    account.create_account_stat!
    account
  end

  it 'rejects an older write after a newer document is stored' do
    group = directory_group('fenced')
    redis.hset(GroupDirectory::Indexing::VERSIONS_KEY, group.id, 2)
    index = described_class::MemoryIndex.new

    described_class.call([group.id], index: index)
    outcome = index.apply(id: group.id, version: 1, document: { 'display_name' => 'old' })

    expect(outcome).to eq(:rejected)
    expect(index.document(group.id)['display_name']).to eq('fenced')
  end

  it 'rebuilds away a document whose enqueue never reached Redis' do
    group = directory_group('kept')
    index = described_class::MemoryIndex.new
    index.apply(id: '999999', version: 1, document: { 'display_name' => 'hidden' })

    described_class.rebuild!(index: index)

    expect(index.document('999999')).to be_nil
    expect(index.document(group.id)['display_name']).to eq('kept')
  end
end
