# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::PendingTargetFeed do
  def create_batch
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  it 'is backed by an ordered pending (batch_id, position, id) index' do
    index = ActiveRecord::Base.connection.indexes(:follow_import_targets)
                              .find { |item| item.name == 'index_follow_import_targets_on_pending_batch_position' }

    expect(index).to be_present
    expect(index.columns).to eq %w(batch_id position id)
    expect(index.where).to include('state = 0')
  end

  it 'walks pending targets in position order without loading the whole batch' do
    batch = create_batch
    5.times { |position| batch.targets.create!(target_key_hash: "p#{position}", position: position) }
    batch.targets.create!(target_key_hash: 'queued', position: 99, state: :queued)

    feed = described_class.new(batch.id, window: 2)
    ids = []
    ids << feed.shift[:id] while feed.remaining?

    expect(ids).to eq(batch.targets.where(state: :pending).order(:position).pluck(:id))
  end

  it 'starts after a reconstructable position cursor and wraps to the first pending row' do
    batch = create_batch
    rows = 3.times.map { |position| batch.targets.create!(target_key_hash: "p#{position}", position: position) }

    feed = described_class.new(batch.id, after_position: rows[1].position, window: 2)
    first = feed.shift

    expect(first[:id]).to eq rows[2].id
    expect(feed.shift[:id]).to eq rows[0].id
    expect(feed.shift[:id]).to eq rows[1].id
    expect(feed.remaining?).to be false
  end

  it 'does not wrap and re-yield when the walk started at the first pending row' do
    batch = create_batch
    3.times { |position| batch.targets.create!(target_key_hash: "p#{position}", position: position) }

    feed = described_class.new(batch.id, window: 2)
    ids = []
    ids << feed.shift[:id] while feed.remaining?

    expect(ids.size).to eq 3
    expect(ids.uniq.size).to eq 3
    expect(feed.remaining?).to be false
  end

  it 'does not load more rows than the remaining scan-target budget' do
    batch = create_batch
    20.times { |position| batch.targets.create!(target_key_hash: "p#{position}", position: position, destination_domain: 'blocked.example') }

    queries = []
    callback = lambda do |*_args, payload|
      sql = payload[:sql]
      next unless sql.include?('follow_import_targets')
      next unless sql.include?('SELECT')
      next if sql.include?('SCHEMA')

      queries << sql
    end

    feed = described_class.new(batch.id, window: 8, max_targets: 10, max_windows: 2)
    seen = []
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      seen << feed.shift[:id] while feed.remaining?
    end

    expect(seen.size).to eq 10
    expect(feed.targets_scanned).to eq 10
    expect(feed.windows_scanned).to be <= 2
    expect(feed.scan_budget_exhausted?).to be true
    expect(queries.size).to be <= 2
    expect(queries).to all(match(/LIMIT/i))
    expect(queries.none? { |sql| sql.match(/LIMIT\s+20\b/i) }).to be true
  end

  it 'wraps from the last pending position even when max_windows_per_batch is 1' do
    batch = create_batch
    rows = 5.times.map { |position| batch.targets.create!(target_key_hash: "p#{position}", position: position) }

    queries = []
    callback = lambda do |*_args, payload|
      sql = payload[:sql]
      next unless sql.include?('follow_import_targets')
      next unless sql.include?('SELECT')
      next if sql.include?('SCHEMA')

      queries << sql
    end

    feed = described_class.new(batch.id, after_position: rows.last.position, window: 8, max_targets: 8, max_windows: 1)
    first = nil
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      first = feed.shift
    end

    expect(first[:id]).to eq rows.first.id
    expect(first[:position]).to eq 0
    expect(feed.windows_scanned).to eq 1
    expect(feed.scan_budget_exhausted?).to be false
    expect(queries.size).to be <= 3
  end

  it 'does not stay parked at the last position across ticks when max_windows is 1' do
    batch = create_batch
    rows = 4.times.map { |position| batch.targets.create!(target_key_hash: "p#{position}", position: position) }

    first = described_class.new(batch.id, after_position: rows.last.position, window: 2, max_targets: 2, max_windows: 1)
    inspected = first.shift
    expect(inspected[:position]).to eq 0

    second = described_class.new(batch.id, after_position: first.last_inspected_position, window: 2, max_targets: 2, max_windows: 1)
    expect(second.shift[:position]).to eq 1
    expect(second.last_inspected_position).not_to eq rows.last.position
  end

  it 'advances last_inspected_position on every inspected row' do
    batch = create_batch
    3.times { |position| batch.targets.create!(target_key_hash: "p#{position}", position: position) }

    feed = described_class.new(batch.id, window: 2)
    feed.shift
    feed.shift

    expect(feed.last_inspected_position).to eq 1
    expect(feed.targets_scanned).to eq 2
  end
end
