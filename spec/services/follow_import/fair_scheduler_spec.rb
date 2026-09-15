# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::FairScheduler do
  class CountingFeed
    attr_reader :shift_calls, :remaining_calls

    def initialize(rows)
      @rows = rows.dup
      @shift_calls = 0
      @remaining_calls = 0
    end

    def shift
      @shift_calls += 1
      @rows.shift
    end

    def remaining?
      @remaining_calls += 1
      @rows.any?
    end
  end

  def feed(rows)
    described_class::ArrayFeed.new(rows)
  end

  def targets(count, batch_id:, domain: 'remote.test')
    Array.new(count) do |index|
      { id: (batch_id * 10_000) + index, position: index, destination_domain: domain }
    end
  end

  def owner(key, batches)
    {
      key: key,
      batches: batches.map { |id, rows| { id: id, feed: feed(rows) } },
    }
  end

  def plan_for(owners, budget:, cursor: FollowImport::FairnessCursor::State.empty, destination_cap: nil)
    described_class.new(budget: budget, owners: owners, cursor: cursor, destination_cap: destination_cap).plan
  end

  it 'never exceeds the shadow plan budget' do
    owners = [owner('A', [[1, targets(20, batch_id: 1)]]), owner('B', [[2, targets(20, batch_id: 2)]])]
    result = plan_for(owners, budget: 7)

    expect(result.planned.size).to eq 7
    expect(result.planned.size).to be <= 7
  end

  it 'shares two equal backlogs within one target' do
    owners = [owner('A', [[1, targets(100, batch_id: 1)]]), owner('B', [[2, targets(100, batch_id: 2)]])]
    counts = plan_for(owners, budget: 10).planned.each_with_object(Hash.new(0)) { |entry, memo| memo[entry.owner_key] += 1 }

    expect((counts['A'] - counts['B']).abs).to be <= 1
    expect(counts['A'] + counts['B']).to eq 10
  end

  it 'lets a small account make progress beside a huge account' do
    owners = [owner('A', [[1, targets(200, batch_id: 1)]]), owner('B', [[2, targets(3, batch_id: 2)]])]
    result = plan_for(owners, budget: 10)
    counts = result.planned.each_with_object(Hash.new(0)) { |entry, memo| memo[entry.owner_key] += 1 }

    expect(counts['B']).to eq 3
    expect(counts['A']).to eq 7
    expect(result.planned.map(&:owner_key).first(2)).to eq %w(A B)
  end

  it 'does not give a split CSV more top-level share than a single-batch account' do
    one_batch = [
      owner('A', [[1, targets(1_000, batch_id: 1)]]),
      owner('B', [[2, targets(1_000, batch_id: 2)]]),
    ]
    ten_batches = [
      owner('A', (10..19).map { |id| [id, targets(100, batch_id: id)] }),
      owner('B', [[2, targets(1_000, batch_id: 2)]]),
    ]

    one = plan_for(one_batch, budget: 10).planned.count { |entry| entry.owner_key == 'A' }
    ten = plan_for(ten_batches, budget: 10).planned.count { |entry| entry.owner_key == 'A' }

    expect(one).to eq 5
    expect(ten).to eq 5
  end

  it 'rotates batches inside one account so all batches make progress' do
    owners = [owner('A', [
                      [10, targets(50, batch_id: 10)],
                      [11, targets(50, batch_id: 11)],
                      [12, targets(2, batch_id: 12)],
                    ])]
    result = plan_for(owners, budget: 8)
    by_batch = result.planned.each_with_object(Hash.new(0)) { |entry, memo| memo[entry.batch_id] += 1 }

    expect(by_batch.keys).to contain_exactly(10, 11, 12)
    expect(by_batch[12]).to eq 2
  end

  it 'advances the owner cursor so a small budget does not starve later accounts' do
    served = []
    cursor = FollowImport::FairnessCursor::State.empty

    4.times do
      owners = ('A'..'J').map { |key| owner(key, [[key.ord, [{ id: key.ord, position: 0, destination_domain: 'd.test' }]]]) }
      result = plan_for(owners, budget: 3, cursor: cursor)
      served.concat(result.planned.map(&:owner_key))
      cursor = result.next_cursor
    end

    expect(served.uniq.sort).to eq(('A'..'J').to_a)
    expect(served.first(3)).to eq %w(A B C)
    expect(served[3, 3]).to eq %w(D E F)
  end

  it 'does not consume an owner share on an empty batch' do
    owners = [
      owner('A', [[1, []], [2, targets(5, batch_id: 2)]]),
      owner('B', [[3, targets(5, batch_id: 3)]]),
    ]
    result = plan_for(owners, budget: 4)
    counts = result.planned.each_with_object(Hash.new(0)) { |entry, memo| memo[entry.owner_key] += 1 }

    expect(counts['A']).to eq 2
    expect(counts['B']).to eq 2
    expect(result.planned.select { |entry| entry.owner_key == 'A' }.map(&:batch_id).uniq).to eq [2]
  end

  it 'is deterministic for identical candidates and cursor' do
    owners = -> { [owner('A', [[1, targets(5, batch_id: 1)]]), owner('B', [[2, targets(5, batch_id: 2)]])] }
    first = plan_for(owners.call, budget: 4)
    second = plan_for(owners.call, budget: 4)

    expect(first.planned.map { |entry| [entry.owner_key, entry.batch_id, entry.target_id] })
      .to eq(second.planned.map { |entry| [entry.owner_key, entry.batch_id, entry.target_id] })
  end

  it 'does not probe remaining? on owners that never receive a turn' do
    feeds = Array.new(40) { |index| CountingFeed.new(targets(5, batch_id: index + 1)) }
    owners = feeds.each_with_index.map do |feed, index|
      { key: format('O%02d', index), batches: [{ id: index + 1, feed: feed }] }
    end
    result = plan_for(owners, budget: 3)

    expect(result.planned.size).to eq 3
    expect(feeds.sum(&:remaining_calls)).to eq 0
    expect(feeds.first(3).sum(&:shift_calls)).to eq 3
    expect(feeds.drop(3).sum(&:shift_calls)).to eq 0
  end

  it 'can optionally share a destination cap across owners, not batches' do
    owners = [
      owner('A', (1..10).map { |id| [id, [{ id: id, position: 0, destination_domain: 'popular.test' }]] }),
      owner('B', [[20, [{ id: 20, position: 0, destination_domain: 'popular.test' }]]]),
    ]
    result = plan_for(owners, budget: 10, destination_cap: 2)
    dest = result.planned.count { |entry| entry.destination_domain == 'popular.test' }
    owners_used = result.planned.map(&:owner_key).uniq

    expect(dest).to eq 2
    expect(owners_used).to include('A', 'B')
    expect(result.planned.count { |entry| entry.owner_key == 'A' }).to eq 1
  end
end
