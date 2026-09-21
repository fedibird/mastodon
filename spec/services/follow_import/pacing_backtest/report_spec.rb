# frozen_string_literal: true

require 'rails_helper'
require_relative 'fixture_builder'

RSpec.describe FollowImport::PacingBacktest::Report do
  def sample_result
    {
      'schema' => 'follow_import_pacing_backtest',
      'schema_version' => 1,
      'generated_at' => '2026-09-16T12:00:00.000000Z',
      'warnings' => [
        FollowImport::PacingBacktest::RIGHT_CENSOR_WARNING,
        FollowImport::PacingBacktest::CAUSAL_WARNING,
      ],
      'observation_window' => {
        'min_event_time' => '2026-09-16T12:00:00.000000Z',
        'max_event_time' => '2026-09-16T12:01:00.000000Z',
        'duration_seconds' => 60.0,
      },
      'baseline' => {
        'first_attempts' => { 'unique_target_count' => 2, 'success_count' => 1 },
        'retry_amplification' => {
          'later_success_observed_within_window' => 0,
          'no_later_success_observed_within_window' => 1,
          'right_censoring_note' => FollowImport::PacingBacktest::RIGHT_CENSOR_WARNING,
        },
      },
      'scenarios' => [
        {
          'name' => 'candidate-a',
          'fixed_cap_pressure' => {
            'first_attempt' => { 'above_either_cap' => 3, 'successful_above_either_cap' => 1 },
          },
          'suppression' => {
            'attempts_in_retry_after_window' => 2,
            'attempts_in_recent_429_window' => 1,
          },
          'adaptive' => { 'available' => false },
          'global_budget_envelope' => { 'available' => false },
        },
      ],
    }
  end

  it 'includes right-censoring and causality warnings and no ranking language' do
    text = described_class.new(sample_result).markdown

    expect(text).to include('right-censored')
    expect(text).to include('Observational constraint exposure')
    expect(text).not_to match(/\b(best|recommended|winner|winning|score)\b/i)
  end
end
