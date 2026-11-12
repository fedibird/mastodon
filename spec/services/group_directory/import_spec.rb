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

  it 'does not acknowledge a delete when Elasticsearch already has that same version' do
    redis.hset(GroupDirectory::Indexing::VERSIONS_KEY, '4242', '1')
    index = described_class::MemoryIndex.new
    index.apply(id: '4242', version: 1, document: { 'display_name' => 'public' })

    expect { described_class.call(['4242'], index: index) }.to raise_error(described_class::VersionGap)
    expect(index.document('4242')['display_name']).to eq('public')
  end

  it 'does not acknowledge a bulk delete conflict at the same version' do
    redis.hset(GroupDirectory::Indexing::VERSIONS_KEY, '4242', '1')
    allow(Chewy.client).to receive(:bulk).and_return(
      'items' => [{
        'delete' => {
          'status' => 409,
          'error' => {
            'type' => 'version_conflict_engine_exception',
            'reason' => '[4242]: version conflict, current version [1] is higher or equal to the one provided [1]',
          },
        },
      }]
    )
    allow(Chewy.client).to receive(:get).and_return('_source' => { 'display_name' => 'public' })

    expect { described_class.call(['4242']) }.to raise_error(described_class::VersionGap)
  end

  it 'does not send a bulk write when the claim expires after the first check' do
    group = directory_group('paused')
    member = "#{group.id}:1"
    redis.zadd(GroupDirectory::Indexing::INFLIGHT_KEY, Time.now.to_i, member)
    allow(GroupDirectory::Indexing).to receive(:claims_writable?).and_return(true, false)
    expect(Chewy.client).not_to receive(:bulk)

    expect { described_class.call([group.id], claims: [member]) }.to raise_error(described_class::StaleClaim)
  end

  it 'does not treat a Redis version reset as a successful stale write' do
    index = described_class::MemoryIndex.new
    index.apply(id: '4242', version: 100, document: { 'display_name' => 'public' })

    expect { described_class.call(['4242'], index: index) }.to raise_error(described_class::VersionGap)
    expect(index.document('4242')['display_name']).to eq('public')
  end

  it 'does not accept a bulk conflict when Elasticsearch is ahead of Redis' do
    payload = {
      'items' => [{
        'delete' => {
          'status' => 409,
          'error' => {
            'type' => 'version_conflict_engine_exception',
            'reason' => '[4242]: version conflict, current version [100] is higher or equal to the one provided [1]',
          },
        },
      }],
    }
    allow(Chewy.client).to receive(:bulk).and_return(payload)

    expect { described_class.call(['4242']) }.to raise_error(described_class::VersionGap)
  end

  it 'does not write a claim that is older than the lease' do
    group = directory_group('late_writer')
    member = "#{group.id}:1"
    redis.zadd(GroupDirectory::Indexing::INFLIGHT_KEY, Time.now.to_i - GroupDirectory::Indexing::INFLIGHT_LEASE - 1, member)
    index = described_class::MemoryIndex.new

    expect { described_class.call([group.id], index: index, claims: [member]) }.to raise_error(described_class::StaleClaim)
    expect(index.document(group.id)).to be_nil
  end

  it 'rebuild removes a group that became unlisted while live sync was off' do
    group = directory_group('hidden_later')
    index = described_class::MemoryIndex.new
    index.apply(id: group.id, version: 1, document: { 'display_name' => 'hidden_later' })
    ENV['GROUP_DIRECTORY_INDEX'] = nil
    group.update!(discoverable: false)

    described_class.rebuild!(index: index)

    expect(index.document(group.id)).to be_nil
  end

  it 'rebuilds away a document whose enqueue never reached Redis' do
    group = directory_group('kept')
    index = described_class::MemoryIndex.new
    index.apply(id: '999999', version: 1, document: { 'display_name' => 'hidden' })

    described_class.rebuild!(index: index)

    expect(index.document('999999')).to be_nil
    expect(index.document(group.id)['display_name']).to eq('kept')
    expect(GroupDirectory::Indexing.backfill_complete?).to be true
  end

  it 'clears the backfill marker when rebuild fails' do
    GroupDirectory::Indexing.mark_backfill_complete!
    allow(GroupDirectory::Eligibility).to receive(:scope).and_raise(RuntimeError, 'boom')

    expect { described_class.rebuild!(index: described_class::MemoryIndex.new) }.to raise_error(RuntimeError, 'boom')
    expect(GroupDirectory::Indexing.backfill_complete?).to be false
  end
end
