# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::FairnessCursor do
  subject(:store) { described_class.new }

  it 'returns a default empty cursor when nothing is stored' do
    state = store.read

    expect(state.source).to eq 'default'
    expect(state.last_owner_key).to be_nil
    expect(state.last_batch_by_owner).to eq({})
  end

  it 'round-trips reconstructable cursor state' do
    written = described_class::State.new(
      last_owner_key: 'a:2',
      last_batch_by_owner: { 'a:2' => 9 },
      last_position_by_batch: { '9' => 4 },
      source: 'redis'
    )

    expect(store.write(written)).to be true
    read = store.read

    expect(read.source).to eq 'redis'
    expect(read.last_owner_key).to eq 'a:2'
    expect(read.last_batch_by_owner).to eq('a:2' => 9)
    expect(read.last_position_by_batch).to eq('9' => 4)
  end

  it 'resets to stable-order default when Redis read fails' do
    allow(store).to receive(:redis).and_raise(Redis::BaseError, 'down')

    state = store.read

    expect(state.source).to eq 'reset'
    expect(state.last_owner_key).to be_nil
  end

  it 'does not raise when Redis write fails' do
    allow(store).to receive(:redis).and_raise(Redis::BaseError, 'down')

    expect(store.write(described_class::State.empty)).to be false
  end

  it 'keeps cursor state for more currently-active owners than the old 500 cap' do
    last_batch = (1..600).each_with_object({}) { |index, memo| memo["a:#{index}"] = index * 2 }
    last_position = (1..600).each_with_object({}) { |index, memo| memo[(index * 2).to_s] = 1 }

    written = described_class::State.new(
      last_owner_key: 'a:600',
      last_batch_by_owner: last_batch,
      last_position_by_batch: last_position,
      source: 'redis'
    )

    expect(store.write(written, active_owner_keys: last_batch.keys, active_batch_ids: last_position.keys)).to be true
    read = store.read

    expect(read.last_batch_by_owner.size).to eq 600
    expect(read.last_batch_by_owner['a:1']).to eq 2
    expect(read.last_batch_by_owner['a:600']).to eq 1_200
    expect(read.last_position_by_batch.size).to eq 600
  end

  it 'prunes inactive owners without evicting still-active batch cursors' do
    store.write(
      described_class::State.new(
        last_owner_key: 'a:3',
        last_batch_by_owner: { 'a:1' => 10, 'a:2' => 20, 'a:3' => 30 },
        last_position_by_batch: { '10' => 1, '20' => 2, '30' => 3 },
        source: 'redis'
      ),
      active_owner_keys: %w(a:2 a:3),
      active_batch_ids: %w(20 30)
    )

    read = store.read

    expect(read.last_batch_by_owner.keys).to contain_exactly('a:2', 'a:3')
    expect(read.last_position_by_batch.keys).to contain_exactly('20', '30')
  end

  it 'preserves per-owner batch rotation across ticks when more than 500 owners are active' do
    owner_count = 520
    budget = 20
    owners = Array.new(owner_count) do |index|
      key = format('o%03d', index)
      first_id = (index * 2) + 1
      second_id = first_id + 1
      {
        key: key,
        first_id: first_id,
        second_id: second_id,
      }
    end

    rebuild = lambda do
      owners.map do |owner|
        {
          key: owner[:key],
          batches: [
            { id: owner[:first_id], feed: FollowImport::FairScheduler::ArrayFeed.new([{ id: owner[:first_id], position: 0, destination_domain: 'd.test' }, { id: owner[:first_id] + 100_000, position: 1, destination_domain: 'd.test' }]) },
            { id: owner[:second_id], feed: FollowImport::FairScheduler::ArrayFeed.new([{ id: owner[:second_id], position: 0, destination_domain: 'd.test' }, { id: owner[:second_id] + 100_000, position: 1, destination_domain: 'd.test' }]) },
          ],
        }
      end
    end

    served = Hash.new { |hash, key| hash[key] = [] }
    cursor = store.read
    ticks = ((owner_count * 2) / budget) + 2

    ticks.times do
      result = FollowImport::FairScheduler.new(budget: budget, owners: rebuild.call, cursor: cursor).plan
      result.planned.each { |entry| served[entry.owner_key] << entry.batch_id }
      store.write(
        result.next_cursor,
        active_owner_keys: owners.map { |owner| owner[:key] },
        active_batch_ids: owners.flat_map { |owner| [owner[:first_id], owner[:second_id]] }
      )
      cursor = store.read
    end

    expect(served.size).to eq owner_count
    expect(served.values).to all(include(an_instance_of(Integer)))
    owners.each do |owner|
      expect(served[owner[:key]].uniq).to contain_exactly(owner[:first_id], owner[:second_id])
    end
  end
end
