# frozen_string_literal: true

require 'rails_helper'
require_relative 'fixture_builder'

RSpec.describe FollowImport::PacingBacktest::AdaptiveReplay do
  include FollowImportPacingBacktestFixtures

  def attempt(overrides = {})
    started = overrides.delete(:event_time) || Time.utc(2026, 9, 16, 12, 0, 0)
    FollowImport::PacingBacktest::Attempt.new(
      row_number: overrides[:row_number] || 1,
      phase: 'activitypub_delivery',
      target_id: overrides[:target_id] || '1',
      destination_domain: overrides[:destination_domain] || 'alpha.example',
      endpoint_origin: overrides[:endpoint_origin] || 'https://inbox.example',
      started_at: started,
      finished_at: started + 1,
      request_started_at: overrides.key?(:request_started_at) ? overrides[:request_started_at] : started,
      request_finished_at: started + 1,
      enqueued_at: started - 1,
      queue_wait_ms: 10,
      request_duration_ms: overrides[:request_duration_ms] || 10,
      outcome: overrides[:outcome] || 'http_success',
      http_status: overrides[:http_status] || 200,
      retry_after_seconds: nil,
      error_class: overrides[:error_class],
      event_time: started,
      attempt_ordinal: overrides[:attempt_ordinal] || 1,
      malformed_fields: []
    )
  end

  def candidate
    FollowImport::PacingBacktest::Scenario::Candidate.new(
      name: 'adaptive-fixture',
      global_budget: nil,
      fixed_profile: FollowImport::RemoteAdmissionProfile.parse(fixed_profile(dest: 4, origin: 4)),
      adaptive_profile: FollowImport::AdaptiveRemoteProfile.parse(adaptive_profile),
      raw: {}
    )
  end

  it 'classifies events through production AdaptiveRemoteObservation' do
    expect(FollowImport::AdaptiveRemoteObservation).to receive(:classify).and_call_original.at_least(:once)

    described_class.new(dataset_for([attempt]), candidate, 60).to_h
  end

  it 'recovers additively on successes and never exceeds the fixed ceiling' do
    rows = 8.times.map do |index|
      attempt(
        target_id: (index + 1).to_s,
        row_number: index + 1,
        event_time: Time.utc(2026, 9, 16, 12, 0, index)
      )
    end
    result = described_class.new(dataset_for(rows), candidate, 60).to_h

    expect(result['destination']['additive_increases']).to be >= 1
    expect(result['destination']['maximum_reached']).to eq 4
    expect(result['destination']['fraction_at_fixed_ceiling']).to be > 0
  end

  it 'applies a multiplicative decrease on generic failure and a stronger decrease on 429' do
    failure_rows = [
      attempt(row_number: 1, http_status: 503, outcome: 'http_retryable', error_class: nil),
    ]
    limited_rows = [
      attempt(row_number: 1, http_status: 429, outcome: 'http_retryable'),
    ]

    failed = described_class.new(dataset_for(failure_rows), candidate, 60).to_h
    limited = described_class.new(dataset_for(limited_rows), candidate, 60).to_h

    expect(failed['destination']['decreases_due_failure']).to eq 1
    expect(failed['destination']['minimum_reached']).to eq 1
    expect(limited['destination']['decreases_due_429']).to eq 1
    expect(limited['destination']['minimum_reached']).to eq 1
  end

  it 'does not mutate state on neutral events or latency' do
    rows = [
      attempt(row_number: 1, http_status: 200, outcome: 'http_success'),
      attempt(row_number: 2, target_id: '2', event_time: Time.utc(2026, 9, 16, 12, 0, 1), http_status: 404, outcome: 'http_unsalvageable', request_duration_ms: 50_000),
    ]
    result = described_class.new(dataset_for(rows), candidate, 60).to_h

    expect(result['destination']['additive_increases']).to eq 0
    expect(result['destination']['decreases_due_failure']).to eq 0
    expect(result['destination']['mutating_event_count']).to eq 1
  end

  it 'resets stale state before applying a later event' do
    rows = [
      attempt(row_number: 1, http_status: 200),
      attempt(row_number: 2, target_id: '2', event_time: Time.utc(2026, 9, 16, 12, 1, 2), http_status: 200),
    ]
    result = described_class.new(dataset_for(rows), candidate, 60).to_h

    expect(result['destination']['stale_resets']).to be >= 1
  end

  it 'keeps destination and origin controllers independent' do
    rows = [
      attempt(row_number: 1, destination_domain: 'alpha.example', endpoint_origin: 'https://one.example', http_status: 503, outcome: 'http_retryable'),
      attempt(row_number: 2, target_id: '2', event_time: Time.utc(2026, 9, 16, 12, 0, 1), destination_domain: 'beta.example', endpoint_origin: 'https://two.example', http_status: 200),
    ]
    result = described_class.new(dataset_for(rows), candidate, 60).to_h

    expect(result['destination']['keys_observed']).to eq 2
    expect(result['origin']['keys_observed']).to eq 2
    expect(result['destination']['decreases_due_failure']).to eq 1
    expect(result['origin']['decreases_due_failure']).to eq 1
  end

  it 'separates first-attempt adaptive pressure from all attempts' do
    rows = [
      attempt(row_number: 1, attempt_ordinal: 1, http_status: 404, outcome: 'http_unsalvageable'),
      attempt(row_number: 2, target_id: '1', attempt_ordinal: 2, event_time: Time.utc(2026, 9, 16, 12, 0, 1), http_status: 404, outcome: 'http_unsalvageable'),
      attempt(row_number: 3, target_id: '2', attempt_ordinal: 1, event_time: Time.utc(2026, 9, 16, 12, 0, 2), http_status: 404, outcome: 'http_unsalvageable'),
      attempt(row_number: 4, target_id: '3', attempt_ordinal: 1, event_time: Time.utc(2026, 9, 16, 12, 0, 3), http_status: 404, outcome: 'http_unsalvageable'),
    ]
    result = described_class.new(dataset_for(rows), candidate, 60).to_h

    expect(result['first_attempt_pressure']['above_either_cap']).to eq 1
    expect(result['all_attempt_pressure']['above_either_cap']).to eq 2
    expect(result['destination']['mutating_event_count']).to eq 0
  end

  it 'treats rows without request-start evidence as adaptive-neutral' do
    rows = [
      attempt(row_number: 1, request_started_at: nil, http_status: 503, outcome: 'timeout', error_class: 'HTTP::TimeoutError'),
    ]
    result = described_class.new(dataset_for(rows), candidate, 60).to_h

    expect(result['destination']['decreases_due_failure']).to eq 0
    expect(result['destination']['mutating_event_count']).to eq 0
  end

  it 'does not persist a stale reset on a neutral event' do
    t0 = Time.utc(2026, 9, 16, 12, 0, 0)
    rows = 8.times.map do |index|
      attempt(
        target_id: (index + 1).to_s,
        row_number: index + 1,
        event_time: t0 + index
      )
    end
    rows << attempt(
      row_number: 9,
      target_id: 'n',
      event_time: t0 + 70,
      http_status: 404,
      outcome: 'http_unsalvageable'
    )
    rows << attempt(
      row_number: 10,
      target_id: 'm',
      event_time: t0 + 71,
      http_status: 200
    )
    result = described_class.new(dataset_for(rows), candidate, 60).to_h

    expect(result['destination']['stale_resets']).to eq 1
    expect(result['destination']['maximum_reached']).to eq 4
    expect(result['destination']['mutating_event_count']).to eq 9
  end

  it 'caps missing destinations in pressure without persisting an unknown key' do
    rows = [
      attempt(row_number: 1, destination_domain: ''),
      attempt(row_number: 2, target_id: '2', event_time: Time.utc(2026, 9, 16, 12, 0, 1), destination_domain: ''),
      attempt(row_number: 3, target_id: '3', event_time: Time.utc(2026, 9, 16, 12, 0, 2), destination_domain: ''),
    ]
    result = described_class.new(dataset_for(rows), candidate, 60).to_h

    expect(result['first_attempt_pressure']['above_destination_cap']).to eq 1
    expect(result['destination']['keys_observed']).to eq 0
    expect(result['destination']['mutating_event_count']).to eq 0
  end

  it 'does not apply remote adaptive dest/origin pressure to a local destination' do
    local = Rails.configuration.x.local_domain
    rows = [
      attempt(row_number: 1, destination_domain: local),
      attempt(row_number: 2, target_id: '2', event_time: Time.utc(2026, 9, 16, 12, 0, 1), destination_domain: local),
      attempt(row_number: 3, target_id: '3', event_time: Time.utc(2026, 9, 16, 12, 0, 2), destination_domain: local),
    ]
    result = described_class.new(dataset_for(rows), candidate, 60).to_h

    expect(result['first_attempt_pressure']['above_destination_cap']).to eq 0
    expect(result['first_attempt_pressure']['above_origin_cap']).to eq 0
    expect(result['destination']['keys_observed']).to eq 0
    expect(result['origin']['keys_observed']).to eq 0
    expect(result['destination']['mutating_event_count']).to eq 0
    expect(result['origin']['mutating_event_count']).to eq 0
  end
end
