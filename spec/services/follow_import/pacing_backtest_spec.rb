# frozen_string_literal: true

require 'rails_helper'
require_relative 'pacing_backtest/fixture_builder'

RSpec.describe FollowImport::PacingBacktest do
  include FollowImportPacingBacktestFixtures

  def build_dir
    Dir.mktmpdir('fi-pacing-backtest')
  end

  def run_backtest(dir, transport_rows:, dispatch_rows: nil, tick_rows: nil, tick_headers: nil, scenarios: nil, now: Time.utc(2026, 9, 21, 7, 0, 0))
    transport = write_transport(File.join(dir, 'transport.csv'), transport_rows)
    scenario_path = write_scenarios(
      File.join(dir, 'scenarios.json'),
      scenarios: scenarios || [default_scenario]
    )
    dispatch = if dispatch_rows
                 write_dispatch(File.join(dir, 'dispatch.csv'), dispatch_rows)
               end
    ticks = if tick_rows
              write_ticks(File.join(dir, 'ticks.csv'), tick_rows, headers: tick_headers)
            end
    described_class.call(
      transport: transport,
      scenarios: scenario_path,
      dispatch: dispatch,
      ticks: ticks,
      out_json: File.join(dir, 'out.json'),
      out_md: File.join(dir, 'out.md'),
      now: now
    )
  end

  def nested_keys(value)
    case value
    when Hash
      value.keys.map(&:to_s) + value.values.flat_map { |item| nested_keys(item) }
    when Array
      value.flat_map { |item| nested_keys(item) }
    else
      []
    end
  end

  it 'produces deterministic JSON aside from generated_at and omits raw domains' do
    dir = build_dir
    rows = [
      transport_row('target_id' => '1', 'outcome' => 'timeout', 'http_status' => '', 'error_class' => 'HTTP::TimeoutError'),
      transport_row('target_id' => '1', 'request_started_at' => '2026-09-16T12:00:20Z', 'started_at' => '2026-09-16T12:00:19Z', 'outcome' => 'http_success'),
      transport_row('target_id' => '2', 'request_started_at' => '2026-09-16T12:00:01Z', 'destination_domain' => 'beta.example', 'endpoint_origin' => 'https://other.example'),
      transport_row('target_id' => '', 'request_started_at' => '2026-09-16T12:00:02Z', 'outcome' => 'http_success'),
      transport_row('target_id' => '3', 'request_started_at' => '2026-09-16T12:00:03Z', 'outcome' => 'connection_failure', 'http_status' => '', 'error_class' => 'HTTP::ConnectionError'),
      transport_row('phase' => 'resolve_account', 'target_id' => '9'),
    ]
    first = run_backtest(dir, transport_rows: rows, now: Time.utc(2026, 9, 21, 7, 0, 0))
    second = run_backtest(dir, transport_rows: rows, now: Time.utc(2026, 9, 21, 8, 0, 0))

    first_copy = first.dup
    second_copy = second.dup
    first_copy.delete('generated_at')
    second_copy.delete('generated_at')
    expect(first_copy).to eq second_copy
    expect(first['generated_at']).not_to eq second['generated_at']

    dumped = JSON.generate(first)
    expect(dumped).not_to include('alpha.example')
    expect(dumped).not_to include('beta.example')
    expect(dumped).not_to include('https://inbox.example')
    expect(dumped).not_to include('https://other.example')
    expect(first['schema']).to eq 'follow_import_pacing_backtest'
    expect(first['schema_version']).to eq 1
    expect(first.dig('baseline', 'retry_amplification', 'later_success_observed_within_window')).to eq 1
    expect(first.dig('baseline', 'retry_amplification', 'no_later_success_observed_within_window')).to eq 1
    expect(first.dig('baseline', 'retry_amplification', 'right_censoring_note')).to include('not a final failure')
    expect(first.dig('baseline', 'dataset', 'actual_http_request_rows')).to eq first.dig('baseline', 'dataset', 'rows_with_request_timestamps')
    expect(File.read(File.join(dir, 'out.md'))).to include('right-censored')
    expect(File.read(File.join(dir, 'out.md'))).to include('Legacy buckets above global budget')
    expect(File.read(File.join(dir, 'out.md'))).not_to match(/\b(best|recommended|winner)\b/i)
  end

  it 'does not invent a CPU/DB safety conclusion field' do
    dir = build_dir
    result = run_backtest(
      dir,
      transport_rows: [transport_row],
      dispatch_rows: [
        { 'observed_at' => '2026-09-16T12:00:00Z', 'claimed_count' => '10', 'candidate_count' => '10', 'global_pending_count' => '10', 'active_batch_count' => '1' },
      ]
    )

    keys = nested_keys(result)
    forbidden = %w(cpu_safe db_safe safe_budget recommended winner active_minutes claims_per_minute)
    expect(keys & forbidden).to eq([])
    expect(result.dig('scenarios', 0, 'global_budget_envelope', 'available')).to be true
    expect(result.dig('scenarios', 0, 'global_budget_envelope', 'cpu_db_note')).to include('CPU or database')
    expect(result.dig('scenarios', 0, 'global_budget_envelope', 'active_buckets')).to be_a(Integer)
    expect(result['warnings'].join).to include('synthetic scheduler tick width')
  end

  it 'marks scheduler tick I2 columns unavailable when the export predates them' do
    dir = build_dir
    result = run_backtest(
      dir,
      transport_rows: [transport_row],
      tick_headers: %w(observed_at scheduler_mode outcome planned_count claimed_count),
      tick_rows: [
        { 'observed_at' => '2026-09-16T12:00:00Z', 'scheduler_mode' => 'shadow', 'outcome' => 'shadow_observed', 'planned_count' => '4', 'claimed_count' => '0' },
      ]
    )

    historical = result.dig('scheduler_ticks', 'historical_pending_count')
    expect(historical['available']).to be false
    expect(historical['count']).to be_nil
    expect(historical['reason']).to include('absent')
  end

  it 'rejects an incompatible adaptive profile and an invalid fixed profile' do
    dir = build_dir
    transport = write_transport(File.join(dir, 't.csv'), [transport_row])
    bad_adaptive = default_scenario
    bad_adaptive['adaptive_profile']['destination']['initial_cap'] = 50
    scenario_path = write_scenarios(File.join(dir, 's.json'), scenarios: [bad_adaptive])

    expect do
      described_class.call(transport: transport, scenarios: scenario_path)
    end.to raise_error(FollowImport::PacingBacktest::Error, /incompatible adaptive profile/)

    invalid_fixed = default_scenario(adaptive: false)
    invalid_fixed['fixed_profile']['destination']['per_tick_cap'] = 0
    invalid_path = write_scenarios(File.join(dir, 's2.json'), scenarios: [invalid_fixed])
    expect do
      described_class.call(transport: transport, scenarios: invalid_path)
    end.to raise_error(FollowImport::PacingBacktest::Error, /invalid fixed profile/)
  end

  it 'documents nearest-rank percentiles' do
    values = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

    expect(FollowImport::PacingBacktest::Distribution.percentile(values, 50)).to eq 5
    expect(FollowImport::PacingBacktest::Distribution.percentile(values, 90)).to eq 9
    expect(FollowImport::PacingBacktest::Distribution.percentile(values, 100)).to eq 10
    expect(FollowImport::PacingBacktest::Distribution.summary([]).fetch('available')).to be false
    expect(FollowImport::PacingBacktest::Distribution.summary([]).fetch('count')).to be_nil
  end

  it 'exposes a rake task for the CLI entry point' do
    Rails.application.load_tasks unless Rake::Task.task_defined?('follow_import:pacing_backtest')

    expect(Rake::Task.task_defined?('follow_import:pacing_backtest')).to be true
  end
end
