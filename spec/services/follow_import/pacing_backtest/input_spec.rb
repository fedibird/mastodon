# frozen_string_literal: true

require 'rails_helper'
require_relative 'fixture_builder'

RSpec.describe FollowImport::PacingBacktest::Input do
  include FollowImportPacingBacktestFixtures

  def tmp(name)
    path = File.join(Dir.mktmpdir('fi-backtest-input'), name)
    path
  end

  def load_rows(rows)
    path = tmp('transport.csv')
    write_transport(path, rows)
    described_class.load(transport: path, scenarios: tmp('unused.json'))
  end

  it 'filters activitypub_delivery and ignores other phases' do
    dataset = load_rows([
                          transport_row('target_id' => '1'),
                          transport_row('target_id' => '2', 'phase' => 'resolve_account'),
                        ])

    expect(dataset.rows.length).to eq 2
    expect(dataset.delivery_rows.map(&:target_id)).to eq ['1']
  end

  it 'prefers request_started_at then started_at for event time' do
    dataset = load_rows([
                          transport_row(
                            'target_id' => '1',
                            'started_at' => '2026-09-16T12:00:05Z',
                            'request_started_at' => '2026-09-16T12:00:01Z'
                          ),
                          transport_row(
                            'target_id' => '2',
                            'started_at' => '2026-09-16T12:00:09Z',
                            'request_started_at' => ''
                          ),
                        ])

    by_id = dataset.timed_rows.index_by(&:target_id)
    expect(by_id['1'].event_time).to eq Time.utc(2026, 9, 16, 12, 0, 1)
    expect(by_id['2'].event_time).to eq Time.utc(2026, 9, 16, 12, 0, 9)
  end

  it 'does not use finished_at as the attempt origin' do
    dataset = load_rows([
                          transport_row(
                            'started_at' => '2026-09-16T12:00:01Z',
                            'request_started_at' => '',
                            'finished_at' => '2026-09-16T12:00:09Z'
                          ),
                        ])

    expect(dataset.timed_rows.first.event_time).to eq Time.utc(2026, 9, 16, 12, 0, 1)
  end

  it 'derives attempt ordinals per target with stable row-number ties' do
    dataset = load_rows([
                          transport_row('target_id' => '1', 'request_started_at' => '2026-09-16T12:00:00Z', 'outcome' => 'timeout'),
                          transport_row('target_id' => '1', 'request_started_at' => '2026-09-16T12:00:00Z', 'outcome' => 'http_success'),
                          transport_row('target_id' => '2', 'request_started_at' => '2026-09-16T12:00:00Z'),
                        ])

    first, second = dataset.timed_rows.select { |row| row.target_id == '1' }.sort_by(&:attempt_ordinal)
    expect(first.attempt_ordinal).to eq 1
    expect(first.outcome).to eq 'timeout'
    expect(second.attempt_ordinal).to eq 2
    expect(dataset.timed_rows.find { |row| row.target_id == '2' }.attempt_ordinal).to eq 1
  end

  it 'keeps missing target ids in delivery rows but not in target-level ordinals' do
    dataset = load_rows([
                          transport_row('target_id' => ''),
                          transport_row('target_id' => '1'),
                        ])

    expect(dataset.missing_target_id_count).to eq 1
    expect(dataset.delivery_rows.length).to eq 2
    expect(dataset.timed_rows.map(&:attempt_ordinal)).to include(nil, 1)
  end

  it 'reports malformed cells instead of coercing them to zero' do
    dataset = load_rows([
                          transport_row('queue_wait_ms' => 'nope', 'http_status' => '200'),
                        ])

    row = dataset.delivery_rows.first
    expect(row.queue_wait_ms).to be_nil
    expect(row.http_status).to eq 200
    expect(dataset.malformed_counts['queue_wait_ms']).to eq 1
  end

  it 'fails when required transport headers are missing' do
    path = tmp('bad.csv')
    File.write(path, "phase,started_at\nactivitypub_delivery,2026-09-16T12:00:00Z\n")

    expect do
      described_class.load(transport: path, scenarios: tmp('unused.json'))
    end.to raise_error(FollowImport::PacingBacktest::Error, /missing required transport headers/)
  end

  it 'fails when there are no usable activitypub_delivery rows' do
    expect do
      load_rows([transport_row('phase' => 'resolve_account')])
    end.to raise_error(FollowImport::PacingBacktest::Error, /no usable activitypub_delivery rows/)
  end

  it 'treats missing optional tick and dispatch files as unavailable rather than zero' do
    path = tmp('transport.csv')
    write_transport(path, [transport_row])
    dataset = described_class.load(transport: path, scenarios: tmp('unused.json'))

    expect(dataset.ticks).to be_nil
    expect(dataset.dispatch_passes).to be_nil
    expect(dataset.warnings.join).to include('unavailable rather than zero')
  end
end
