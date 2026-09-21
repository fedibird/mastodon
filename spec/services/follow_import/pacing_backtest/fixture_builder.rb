# frozen_string_literal: true

require 'csv'
require 'json'

module FollowImportPacingBacktestFixtures
  TRANSPORT_HEADERS = FollowImport::PacingBacktest::Input::REQUIRED_TRANSPORT_HEADERS

  module_function

  def write_csv(path, headers, rows)
    CSV.open(path, 'w') do |csv|
      csv << headers
      rows.each do |row|
        csv << headers.map { |header| row[header] }
      end
    end
    path
  end

  def transport_row(overrides = {})
    {
      'target_id' => '1',
      'phase' => 'activitypub_delivery',
      'destination_domain' => 'alpha.example',
      'endpoint_origin' => 'https://inbox.example',
      'started_at' => '2026-09-16T12:00:00Z',
      'finished_at' => '2026-09-16T12:00:01Z',
      'request_started_at' => '2026-09-16T12:00:00Z',
      'request_finished_at' => '2026-09-16T12:00:01Z',
      'enqueued_at' => '2026-09-16T11:59:59Z',
      'queue_wait_ms' => '1000',
      'request_duration_ms' => '1000',
      'outcome' => 'http_success',
      'http_status' => '200',
      'retry_after_seconds' => '',
      'error_class' => '',
    }.merge(overrides)
  end

  def write_transport(path, rows)
    write_csv(path, TRANSPORT_HEADERS, rows)
  end

  def write_dispatch(path, rows)
    headers = %w(observed_at claimed_count candidate_count global_pending_count active_batch_count)
    write_csv(path, headers, rows)
  end

  def write_ticks(path, rows, headers: nil)
    headers ||= %w(
      observed_at
      scheduler_mode
      outcome
      planned_count
      claimed_count
      global_base_budget
      effective_global_budget
      global_pending_count
      historical_pending_count
      operational_pending_count
      planning_pending_count
    )
    write_csv(path, headers, rows)
  end

  def fixed_profile(dest: 2, origin: 2)
    {
      'version' => 1,
      'destination' => { 'per_tick_cap' => dest },
      'origin' => { 'per_tick_cap' => origin },
      'runtime' => {
        'mapping_ttl_seconds' => 3600,
        'max_retry_after_seconds' => 60,
        'recent_429_cooldown_seconds' => 30,
      },
      'scan' => {
        'max_targets_per_batch' => 10,
        'max_windows_per_batch' => 4,
      },
    }
  end

  def adaptive_profile
    {
      'version' => 1,
      'destination' => controller_params,
      'origin' => controller_params,
      'runtime' => {
        'stale_after_seconds' => 60,
        'state_ttl_seconds' => 120,
      },
    }
  end

  def controller_params
    {
      'initial_cap' => 2,
      'min_cap' => 1,
      'additive_step' => 1,
      'successes_per_increase' => 2,
      'failure_multiplier_percent' => 50,
      'rate_limit_multiplier_percent' => 25,
    }
  end

  def write_scenarios(path, scenarios:, bucket_seconds: 60)
    payload = {
      'schema_version' => 1,
      'bucket_seconds' => bucket_seconds,
      'scenarios' => scenarios,
    }
    File.write(path, JSON.pretty_generate(payload))
    path
  end

  def default_scenario(name: 'candidate-a', global_budget: 2, adaptive: true)
    payload = {
      'name' => name,
      'global_budget' => global_budget,
      'fixed_profile' => fixed_profile,
    }
    payload['adaptive_profile'] = adaptive_profile if adaptive
    payload
  end
end
