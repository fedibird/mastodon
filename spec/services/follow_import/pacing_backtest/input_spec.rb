# frozen_string_literal: true

require 'rails_helper'
require_relative 'fixture_builder'

RSpec.describe FollowImport::PacingBacktest::Input do # rubocop:disable Metrics/BlockLength
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

  it 'fails when there are no usable timed activitypub_delivery rows' do
    expect do
      load_rows([
                  transport_row(
                    'started_at' => '',
                    'request_started_at' => '',
                    'finished_at' => '',
                    'enqueued_at' => ''
                  ),
                ])
    end.to raise_error(FollowImport::PacingBacktest::Error, /no usable timed activitypub_delivery rows/)
  end

  it 'reports malformed optional tick and dispatch cells at load time' do
    dir = Dir.mktmpdir('fi-malformed-optional')
    transport = write_transport(File.join(dir, 't.csv'), [transport_row])
    write_dispatch(File.join(dir, 'd.csv'), [
                     { 'observed_at' => 'not-a-time', 'claimed_count' => 'nope', 'candidate_count' => '1', 'global_pending_count' => '1', 'active_batch_count' => '1' },
                   ])
    write_ticks(File.join(dir, 'k.csv'), [
                  { 'observed_at' => '2026-09-16T12:00:00Z', 'scheduler_mode' => 'shadow', 'outcome' => 'shadow_observed', 'planned_count' => 'x', 'claimed_count' => '0' },
                ], headers: %w(observed_at scheduler_mode outcome planned_count claimed_count))

    dataset = described_class.load(
      transport: transport,
      scenarios: File.join(dir, 'unused.json'),
      dispatch: File.join(dir, 'd.csv'),
      ticks: File.join(dir, 'k.csv')
    )

    expect(dataset.malformed_counts['dispatch.observed_at']).to eq 1
    expect(dataset.malformed_counts['dispatch.claimed_count']).to eq 1
    expect(dataset.malformed_counts['ticks.planned_count']).to eq 1
  end

  def load_anonymous(rows)
    path = tmp('anon.csv')
    write_anonymous_transport(path, rows)
    described_class.load(transport: path, scenarios: tmp('unused.json'))
  end

  it 'reports raw routing identity mode for existing destination/origin headers' do
    dataset = load_rows([transport_row])

    expect(dataset.routing_identity_mode).to eq 'raw'
    expect(dataset.delivery_rows.first.destination_domain).to eq 'alpha.example'
    expect(dataset.delivery_rows.first.destination_is_local).to eq false
  end

  it 'uses an explicit destination_is_local hint in raw mode when present' do
    path = tmp('raw-hint.csv')
    write_csv(path, FollowImportPacingBacktestFixtures::TRANSPORT_HEADERS + ['destination_is_local'], [transport_row('destination_is_local' => 't')])
    dataset = described_class.load(transport: path, scenarios: tmp('unused.json'))

    expect(dataset.routing_identity_mode).to eq 'raw'
    expect(dataset.delivery_rows.first.destination_is_local).to eq true
  end

  it 'loads anonymous destination/origin headers with explicit locality' do
    dataset = load_anonymous([anonymous_transport_row])

    expect(dataset.routing_identity_mode).to eq 'anonymous'
    row = dataset.delivery_rows.first
    expect(row.destination_domain).to eq 'd0000972'
    expect(row.endpoint_origin).to eq 'o0000abcd'
    expect(row.destination_is_local).to eq false
    expect(dataset.warnings.join).to include('not guaranteed to be stable across separately generated exports')
  end

  it 'fails when anonymous routing headers are incomplete' do
    path = tmp('incomplete.csv')
    headers = FollowImport::PacingBacktest::Input::CORE_TRANSPORT_HEADERS + %w(anon_destination_domain anon_endpoint_origin)
    write_csv(path, headers, [anonymous_transport_row])

    expect do
      described_class.load(transport: path, scenarios: tmp('unused.json'))
    end.to raise_error(FollowImport::PacingBacktest::Error, /incomplete or mixed transport routing headers/)
  end

  it 'fails when raw and anonymous routing headers are mixed or both complete' do
    mixed = tmp('mixed.csv')
    mixed_headers = FollowImport::PacingBacktest::Input::CORE_TRANSPORT_HEADERS + %w(destination_domain anon_endpoint_origin)
    write_csv(mixed, mixed_headers, [transport_row.merge('anon_endpoint_origin' => 'o0000abcd')])
    expect do
      described_class.load(transport: mixed, scenarios: tmp('unused.json'))
    end.to raise_error(FollowImport::PacingBacktest::Error, /incomplete or mixed transport routing headers/)

    both = tmp('both.csv')
    both_headers = FollowImportPacingBacktestFixtures::TRANSPORT_HEADERS + FollowImport::PacingBacktest::Input::ANONYMOUS_ROUTING_HEADERS
    write_csv(both, both_headers, [transport_row.merge(anonymous_transport_row)])
    expect do
      described_class.load(transport: both, scenarios: tmp('unused.json'))
    end.to raise_error(FollowImport::PacingBacktest::Error, /ambiguous transport routing headers/)
  end

  it 'fails when an anonymous nonblank destination is missing locality' do
    expect do
      load_anonymous([anonymous_transport_row('destination_is_local' => '')])
    end.to raise_error(FollowImport::PacingBacktest::Error, /anonymous transport row 1: missing destination_is_local/)
  end

  it 'fails when an anonymous locality value is invalid' do
    expect do
      load_anonymous([anonymous_transport_row('destination_is_local' => 'maybe')])
    end.to raise_error(FollowImport::PacingBacktest::Error, /anonymous transport row 1: invalid destination_is_local/)
  end

  it 'allows a blank anonymous destination to omit locality' do
    dataset = load_anonymous([
                               anonymous_transport_row(
                                 'anon_destination_domain' => '',
                                 'destination_is_local' => ''
                               ),
                             ])

    row = dataset.delivery_rows.first
    expect(row.destination_domain).to be_nil
    expect(row.destination_is_local).to be_nil
  end

  it 'parses PostgreSQL and explicit boolean locality cells' do
    %w(t true 1 T TRUE).each do |value|
      dataset = load_anonymous([anonymous_transport_row('destination_is_local' => value)])
      expect(dataset.delivery_rows.first.destination_is_local).to eq(true), value
    end
    %w(f false 0 F FALSE).each do |value|
      dataset = load_anonymous([anonymous_transport_row('destination_is_local' => value)])
      expect(dataset.delivery_rows.first.destination_is_local).to eq(false), value
    end
  end

  it 'does not coerce an unknown locality cell to false' do
    expect do
      load_anonymous([anonymous_transport_row('destination_is_local' => 'nope')])
    end.to raise_error(FollowImport::PacingBacktest::Error, /invalid destination_is_local/)
  end
end
