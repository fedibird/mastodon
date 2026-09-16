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

  def plan_for(owners, budget:, cursor: FollowImport::FairnessCursor::State.empty, admission: nil, scan_policy: nil)
    described_class.new(budget: budget, owners: owners, cursor: cursor, admission: admission, scan_policy: scan_policy).plan
  end

  def test_profile(**caps)
    FollowImport::RemoteAdmissionProfile.parse(
      version: 1,
      destination: { per_tick_cap: caps.fetch(:destination, 3) },
      origin: { per_tick_cap: caps.fetch(:origin, 10) },
      runtime: {
        mapping_ttl_seconds: 3600,
        max_retry_after_seconds: 120,
        recent_429_cooldown_seconds: 30,
      },
      scan: {
        max_targets_per_batch: caps.fetch(:max_targets, 50),
        max_windows_per_batch: caps.fetch(:max_windows, 8),
      }
    )
  end

  def admission_for(profile:, mappings: {}, suppressions: {}, hosts: [], available: true)
    runtime = Object.new
    runtime.define_singleton_method(:available?) { available }
    runtime.define_singleton_method(:mapping_for) do |domain|
      origin = mappings[domain]
      next if origin.blank?

      FollowImport::RemoteRuntimeState::Mapping.new(endpoint_origin: origin, observed_at: Time.now.utc)
    end
    runtime.define_singleton_method(:suppression_for) { |origin| suppressions[origin] }
    FollowImport::RemoteAdmission.new(
      profile: profile,
      runtime: runtime,
      unavailable_hosts: hosts.to_set,
      unavailable_snapshot_available: true
    )
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

  it 'shares a destination cap across owners through account-first rotation, not batches' do
    owners = [
      owner('A', (1..10).map { |id| [id, [{ id: id, position: 0, destination_domain: 'popular.test' }]] }),
      owner('B', [[20, [{ id: 20, position: 0, destination_domain: 'popular.test' }]]]),
    ]
    result = plan_for(owners, budget: 10, admission: admission_for(profile: test_profile(destination: 2)))
    dest = result.planned.count { |entry| entry.destination_domain == 'popular.test' }
    owners_used = result.planned.map(&:owner_key).uniq

    expect(dest).to eq 2
    expect(owners_used).to include('A', 'B')
    expect(result.planned.count { |entry| entry.owner_key == 'A' }).to eq 1
  end

  it 'does not multiply a destination cap when one account splits the same remote across many batches' do
    owners = [
      owner('A', (1..10).map { |id| [id, [{ id: id, position: 0, destination_domain: 'remote.example' }]] }),
    ]
    result = plan_for(owners, budget: 10, admission: admission_for(profile: test_profile(destination: 3)))

    expect(result.planned.size).to eq 3
    expect(result.planned.map(&:destination_domain).uniq).to eq ['remote.example']
  end

  it 'lets two remotes progress independently under the same destination cap' do
    owners = [
      owner('A', [[1, targets(10, batch_id: 1, domain: 'remote-a.example')]]),
      owner('B', [[2, targets(10, batch_id: 2, domain: 'remote-b.example')]]),
    ]
    result = plan_for(owners, budget: 10, admission: admission_for(profile: test_profile(destination: 3)))
    by_dest = result.planned.each_with_object(Hash.new(0)) { |entry, memo| memo[entry.destination_domain] += 1 }

    expect(by_dest['remote-a.example']).to eq 3
    expect(by_dest['remote-b.example']).to eq 3
    expect(result.planned.size).to eq 6
  end

  it 'shares destination capacity through owner rotation rather than letting ten batches of A go first' do
    owners = [
      owner('A', (1..10).map { |id| [id, [{ id: id, position: 0, destination_domain: 'remote.example' }]] }),
      owner('B', [[20, [{ id: 200, position: 0, destination_domain: 'remote.example' }]]]),
    ]
    result = plan_for(owners, budget: 5, admission: admission_for(profile: test_profile(destination: 5)))
    counts = result.planned.each_with_object(Hash.new(0)) { |entry, memo| memo[entry.owner_key] += 1 }

    expect((counts['A'] - counts['B']).abs).to be <= 1
    expect(counts['A'] + counts['B']).to eq 5
    expect(counts['A']).to be < 10
  end

  it 'enforces a shared origin cap across mapped destinations and ignores unknown mappings' do
    owners = [
      owner('A', [[1, targets(5, batch_id: 1, domain: 'a.example')]]),
      owner('B', [[2, targets(5, batch_id: 2, domain: 'b.example')]]),
      owner('C', [[3, targets(5, batch_id: 3, domain: 'c.example')]]),
    ]
    admission = admission_for(
      profile: test_profile(destination: 3, origin: 2),
      mappings: { 'a.example' => 'https://shared.example', 'b.example' => 'https://shared.example' }
    )
    result = plan_for(owners, budget: 10, admission: admission)
    shared = result.planned.count { |entry| %w(a.example b.example).include?(entry.destination_domain) }
    unknown = result.planned.count { |entry| entry.destination_domain == 'c.example' }

    expect(shared).to eq 2
    expect(unknown).to eq 3
  end

  it 'skips a blocked prefix and plans a later healthy destination inside the scan budget' do
    blocked = 50.times.map { |index| { id: index, position: index, destination_domain: 'blocked.example' } }
    healthy = 10.times.map { |index| { id: 100 + index, position: 50 + index, destination_domain: 'healthy.example' } }
    owners = [owner('A', [[1, blocked + healthy]])]
    admission = admission_for(
      profile: test_profile(destination: 3, max_targets: 60),
      hosts: ['blocked.example']
    )
    result = plan_for(owners, budget: 5, admission: admission, scan_policy: test_profile(destination: 3, max_targets: 60).scan_policy)

    expect(result.planned.map(&:destination_domain).uniq).to eq ['healthy.example']
    expect(result.planned.size).to eq 3
    expect(result.next_cursor.last_position_by_batch['1']).to eq(52)
    expect(result.admission_stats['skipped_unavailable_count']).to eq 50
    expect(result.admission_stats['scan_budget_exhausted_count']).to eq 0
  end

  it 'records scan_budget_exhausted and does not reach a healthy row outside the scan bound' do
    blocked = 50.times.map { |index| { id: index, position: index, destination_domain: 'blocked.example' } }
    healthy = [{ id: 100, position: 50, destination_domain: 'healthy.example' }]
    owners = [owner('A', [[1, blocked + healthy]])]
    policy = FollowImport::RemoteAdmission::ScanPolicy.new(max_targets_per_batch: 10, max_windows_per_batch: 2)
    admission = admission_for(profile: test_profile(destination: 3, max_targets: 10), hosts: ['blocked.example'])
    result = plan_for(owners, budget: 5, admission: admission, scan_policy: policy)

    expect(result.planned).to be_empty
    expect(result.next_cursor.last_position_by_batch['1']).to eq 9
    expect(result.admission_stats['scan_budget_exhausted_count']).to eq 1
    expect(result.admission_stats['scanned_target_count']).to eq 10
  end

  it 'continues from the inspected cursor so a later tick can reach the healthy row' do
    blocked = 50.times.map { |index| { id: index, position: index, destination_domain: 'blocked.example' } }
    healthy = [{ id: 100, position: 50, destination_domain: 'healthy.example' }]
    policy = FollowImport::RemoteAdmission::ScanPolicy.new(max_targets_per_batch: 20, max_windows_per_batch: 4)
    admission = admission_for(profile: test_profile(destination: 3, max_targets: 20), hosts: ['blocked.example'])
    cursor = FollowImport::FairnessCursor::State.empty
    planned = []

    4.times do
      owners = [owner('A', [[1, blocked + healthy]])]
      # Simulate the feed starting after the persisted inspection cursor.
      after = cursor.last_position_by_batch['1']
      rows = (blocked + healthy).select { |row| after.nil? || row[:position] > after }
      owners = [owner('A', [[1, rows]])]
      result = plan_for(owners, budget: 1, admission: admission, scan_policy: policy, cursor: cursor)
      planned.concat(result.planned)
      cursor = result.next_cursor
      break if planned.any?
    end

    expect(planned.map(&:destination_domain)).to eq ['healthy.example']
  end

  it 'lets a healthy owner progress when another owner has only blocked remotes' do
    owners = [
      owner('A', [[1, targets(10, batch_id: 1, domain: 'blocked.example')]]),
      owner('B', [[2, targets(10, batch_id: 2, domain: 'healthy.example')]]),
    ]
    result = plan_for(
      owners,
      budget: 4,
      admission: admission_for(profile: test_profile(destination: 4), hosts: ['blocked.example'])
    )

    expect(result.planned.map(&:owner_key).uniq).to eq ['B']
    expect(result.planned.size).to eq 4
  end

  it 'searches another batch of the same owner when the first batch is blocked' do
    owners = [
      owner('A', [
              [1, targets(8, batch_id: 1, domain: 'blocked.example')],
              [2, targets(8, batch_id: 2, domain: 'healthy.example')],
            ]),
    ]
    result = plan_for(
      owners,
      budget: 3,
      admission: admission_for(profile: test_profile(destination: 3), hosts: ['blocked.example'])
    )

    expect(result.planned.map(&:batch_id).uniq).to eq [2]
    expect(result.planned.size).to eq 3
  end

  it 'does not consume global budget on remote-blocked candidates' do
    owners = [
      owner('A', [[1, targets(20, batch_id: 1, domain: 'blocked.example') + targets(5, batch_id: 1, domain: 'healthy.example')]]),
    ]
    # Rebuild with mixed destinations in one feed
    mixed = 20.times.map { |index| { id: index, position: index, destination_domain: 'blocked.example' } }
    mixed += 5.times.map { |index| { id: 100 + index, position: 20 + index, destination_domain: 'healthy.example' } }
    owners = [owner('A', [[1, mixed]])]
    result = plan_for(
      owners,
      budget: 4,
      admission: admission_for(profile: test_profile(destination: 4), hosts: ['blocked.example'])
    )

    expect(result.planned.size).to eq 4
    expect(result.planned.map(&:destination_domain).uniq).to eq ['healthy.example']
  end

  it 'keeps last_position_by_batch advancing over blocked inspections without planning them' do
    rows = 5.times.map { |index| { id: index, position: index, destination_domain: 'blocked.example' } }
    owners = [owner('A', [[7, rows]])]
    result = plan_for(owners, budget: 3, admission: admission_for(profile: test_profile(destination: 3), hosts: ['blocked.example']))

    expect(result.planned).to be_empty
    expect(result.next_cursor.last_position_by_batch['7']).to eq 4
    expect(result.next_cursor.last_owner_key).to be_nil
  end
end
