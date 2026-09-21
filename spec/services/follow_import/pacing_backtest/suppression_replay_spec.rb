# frozen_string_literal: true

require 'rails_helper'
require_relative 'fixture_builder'

RSpec.describe FollowImport::PacingBacktest::SuppressionReplay do
  include FollowImportPacingBacktestFixtures

  def attempt(overrides = {})
    started = overrides.delete(:event_time) || Time.utc(2026, 9, 16, 12, 0, 0)
    FollowImport::PacingBacktest::Attempt.new(
      row_number: overrides[:row_number] || 1,
      phase: 'activitypub_delivery',
      target_id: overrides[:target_id] || '1',
      destination_domain: 'alpha.example',
      endpoint_origin: overrides[:endpoint_origin] || 'https://inbox.example',
      started_at: started,
      finished_at: started + 1,
      request_started_at: started,
      request_finished_at: started + 1,
      enqueued_at: started - 1,
      queue_wait_ms: 1000,
      request_duration_ms: 1000,
      outcome: overrides[:outcome] || 'http_retryable',
      http_status: overrides[:http_status] || 429,
      retry_after_seconds: overrides[:retry_after_seconds],
      error_class: nil,
      event_time: started,
      attempt_ordinal: overrides[:attempt_ordinal] || 1,
      malformed_fields: []
    )
  end

  def profile(max_retry: 60, cooldown: 30)
    FollowImport::RemoteAdmissionProfile.parse(fixed_profile.merge(
                                                 'runtime' => {
                                                   'mapping_ttl_seconds' => 3600,
                                                   'max_retry_after_seconds' => max_retry,
                                                   'recent_429_cooldown_seconds' => cooldown,
                                                 }
                                               ))
  end

  it 'caps Retry-After using the profile maximum' do
    rows = [
      attempt(event_time: Time.utc(2026, 9, 16, 12, 0, 0), retry_after_seconds: 600, row_number: 1),
      attempt(event_time: Time.utc(2026, 9, 16, 12, 0, 59), target_id: '2', row_number: 2, http_status: 200, outcome: 'http_success', retry_after_seconds: nil),
      attempt(event_time: Time.utc(2026, 9, 16, 12, 1, 1), target_id: '3', row_number: 3, http_status: 200, outcome: 'http_success', retry_after_seconds: nil),
    ]
    result = described_class.new(rows, profile(max_retry: 60)).to_h

    expect(result['attempts_in_retry_after_window']).to eq 1
    expect(result['unique_targets']).to eq 1
  end

  it 'keeps the later honor_until when suppression is repeated' do
    rows = [
      attempt(event_time: Time.utc(2026, 9, 16, 12, 0, 0), retry_after_seconds: 30, row_number: 1),
      attempt(event_time: Time.utc(2026, 9, 16, 12, 0, 10), retry_after_seconds: 60, target_id: '1', attempt_ordinal: 2, row_number: 2),
      attempt(event_time: Time.utc(2026, 9, 16, 12, 1, 5), target_id: '2', row_number: 3, http_status: 200, outcome: 'http_success', retry_after_seconds: nil),
    ]
    result = described_class.new(rows, profile(max_retry: 120)).to_h

    expect(result['attempts_in_retry_after_window']).to eq 2
  end

  it 'uses recent-429 cooldown when Retry-After is absent' do
    rows = [
      attempt(event_time: Time.utc(2026, 9, 16, 12, 0, 0), http_status: 429, retry_after_seconds: nil, row_number: 1),
      attempt(event_time: Time.utc(2026, 9, 16, 12, 0, 15), target_id: '2', row_number: 2, http_status: 200, outcome: 'http_success', retry_after_seconds: nil),
      attempt(event_time: Time.utc(2026, 9, 16, 12, 0, 31), target_id: '3', row_number: 3, http_status: 200, outcome: 'http_success', retry_after_seconds: nil),
    ]
    result = described_class.new(rows, profile(cooldown: 30)).to_h

    expect(result['attempts_in_recent_429_window']).to eq 1
    expect(result['attempts_in_retry_after_window']).to eq 0
  end

  it 'splits in-window attempts into first vs retry' do
    rows = [
      attempt(event_time: Time.utc(2026, 9, 16, 12, 0, 0), retry_after_seconds: 60, attempt_ordinal: 1, row_number: 1),
      attempt(event_time: Time.utc(2026, 9, 16, 12, 0, 10), target_id: '1', attempt_ordinal: 2, row_number: 2, retry_after_seconds: nil, http_status: 200, outcome: 'http_success'),
      attempt(event_time: Time.utc(2026, 9, 16, 12, 0, 11), target_id: '2', attempt_ordinal: 1, row_number: 3, retry_after_seconds: nil, http_status: 200, outcome: 'http_success'),
    ]
    result = described_class.new(rows, profile).to_h

    expect(result['first_attempts_in_window']).to eq 1
    expect(result['retry_attempts_in_window']).to eq 1
    expect(result['note']).to include('not a full-system counterfactual')
  end

  it 'does not count a pre-request interruption inside a suppression window' do
    rows = [
      attempt(event_time: Time.utc(2026, 9, 16, 12, 0, 0), retry_after_seconds: 60, row_number: 1),
      FollowImport::PacingBacktest::Attempt.new(
        row_number: 2,
        phase: 'activitypub_delivery',
        target_id: '9',
        destination_domain: 'alpha.example',
        endpoint_origin: 'https://inbox.example',
        started_at: Time.utc(2026, 9, 16, 12, 0, 10),
        finished_at: Time.utc(2026, 9, 16, 12, 0, 11),
        request_started_at: nil,
        request_finished_at: nil,
        enqueued_at: Time.utc(2026, 9, 16, 12, 0, 9),
        queue_wait_ms: 10,
        request_duration_ms: nil,
        outcome: 'circuit_or_stoplight_interruption',
        http_status: nil,
        retry_after_seconds: nil,
        error_class: 'Stoplight::Error::RedLight',
        event_time: Time.utc(2026, 9, 16, 12, 0, 10),
        attempt_ordinal: 1,
        malformed_fields: []
      ),
    ]
    result = described_class.new(rows, profile).to_h

    expect(result['attempts_in_retry_after_window']).to eq 0
    expect(result['unique_targets']).to eq 0
  end
end
