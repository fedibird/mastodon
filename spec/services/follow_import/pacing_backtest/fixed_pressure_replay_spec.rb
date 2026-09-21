# frozen_string_literal: true

require 'rails_helper'
require_relative 'fixture_builder'

RSpec.describe FollowImport::PacingBacktest::FixedPressureReplay do
  include FollowImportPacingBacktestFixtures

  def attempt(overrides = {})
    data = transport_row(overrides)
    FollowImport::PacingBacktest::Attempt.new(
      row_number: overrides[:row_number] || 1,
      phase: 'activitypub_delivery',
      target_id: data['target_id'],
      destination_domain: data['destination_domain'],
      endpoint_origin: data['endpoint_origin'],
      started_at: Time.iso8601(data['started_at']),
      finished_at: Time.iso8601(data['finished_at']),
      request_started_at: Time.iso8601(data['request_started_at']),
      request_finished_at: Time.iso8601(data['request_finished_at']),
      enqueued_at: Time.iso8601(data['enqueued_at']),
      queue_wait_ms: data['queue_wait_ms'].to_i,
      request_duration_ms: data['request_duration_ms'].to_i,
      outcome: data['outcome'],
      http_status: data['http_status'].to_i,
      retry_after_seconds: nil,
      error_class: nil,
      event_time: Time.iso8601(data['request_started_at']),
      attempt_ordinal: overrides[:attempt_ordinal] || 1,
      malformed_fields: []
    )
  end

  def profile
    FollowImport::RemoteAdmissionProfile.parse(fixed_profile(dest: 2, origin: 2))
  end

  it 'counts destination cap excess, origin cap excess, and either-cap without double counting' do
    rows = [
      attempt('target_id' => '1', :row_number => 1, :attempt_ordinal => 1),
      attempt('target_id' => '2', :row_number => 2, :attempt_ordinal => 1, 'request_started_at' => '2026-09-16T12:00:01Z'),
      attempt('target_id' => '3', :row_number => 3, :attempt_ordinal => 1, 'request_started_at' => '2026-09-16T12:00:02Z', 'outcome' => 'timeout', 'http_status' => ''),
    ]
    rows.last.http_status = nil
    result = described_class.new(rows, profile, 60).first_attempt

    expect(result['above_destination_cap']).to eq 1
    expect(result['above_origin_cap']).to eq 1
    expect(result['above_either_cap']).to eq 1
    expect(result['successful_above_either_cap']).to eq 0
    expect(result['failed_above_either_cap']).to eq 1
  end

  it 'separates successful vs failed constrained rows' do
    rows = [
      attempt('target_id' => '1', :row_number => 1),
      attempt('target_id' => '2', :row_number => 2, 'request_started_at' => '2026-09-16T12:00:01Z'),
      attempt('target_id' => '3', :row_number => 3, 'request_started_at' => '2026-09-16T12:00:02Z'),
      attempt('target_id' => '4', :row_number => 4, 'request_started_at' => '2026-09-16T12:00:03Z', 'outcome' => 'timeout'),
    ]
    result = described_class.new(rows, profile, 60).first_attempt

    expect(result['above_either_cap']).to eq 2
    expect(result['successful_above_either_cap']).to eq 1
    expect(result['failed_above_either_cap']).to eq 1
  end

  it 'keeps first-attempt and all-attempt views distinct when retries exist' do
    rows = [
      attempt('target_id' => '1', :row_number => 1, :attempt_ordinal => 1),
      attempt('target_id' => '2', :row_number => 2, :attempt_ordinal => 1, 'request_started_at' => '2026-09-16T12:00:01Z'),
      attempt('target_id' => '1', :row_number => 3, :attempt_ordinal => 2, 'request_started_at' => '2026-09-16T12:00:02Z'),
    ]
    replay = described_class.new(rows, profile, 60)

    expect(replay.first_attempt['observed_attempts']).to eq 2
    expect(replay.first_attempt['above_either_cap']).to eq 0
    expect(replay.all_attempt['observed_attempts']).to eq 3
    expect(replay.all_attempt['above_either_cap']).to eq 1
  end

  it 'does not reflow excess into a later bucket' do
    rows = [
      attempt('target_id' => '1', :row_number => 1),
      attempt('target_id' => '2', :row_number => 2, 'request_started_at' => '2026-09-16T12:00:01Z'),
      attempt('target_id' => '3', :row_number => 3, 'request_started_at' => '2026-09-16T12:00:02Z'),
      attempt('target_id' => '4', :row_number => 4, 'request_started_at' => '2026-09-16T12:01:00Z'),
    ]
    result = described_class.new(rows, profile, 60).first_attempt

    expect(result['above_either_cap']).to eq 1
    expect(result).not_to have_key('reflowed_attempts')
    expect(result['reflow']).to include('not moved into later buckets')
  end
end
