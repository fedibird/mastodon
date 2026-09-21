# frozen_string_literal: true

require 'rails_helper'
require_relative 'fixture_builder'

RSpec.describe FollowImport::PacingBacktest::GlobalEnvelope do
  include FollowImportPacingBacktestFixtures

  it 'reports unavailable rather than zero when dispatch input is missing' do
    result = described_class.new(nil, 50, 60).to_h

    expect(result['available']).to be false
    expect(result['reason']).to include('not supplied')
    expect(result.keys).not_to include('active_minutes')
    expect(result.keys).not_to include('cpu_safe')
    expect(result.keys).not_to include('db_safe')
  end

  it 'computes claims/min distribution and budget excess without reflow' do
    dir = Dir.mktmpdir('fi-envelope')
    path = File.join(dir, 'dispatch.csv')
    write_dispatch(path, [
                     { 'observed_at' => '2026-09-16T12:00:00Z', 'claimed_count' => '4', 'candidate_count' => '4', 'global_pending_count' => '10', 'active_batch_count' => '1' },
                     { 'observed_at' => '2026-09-16T12:00:30Z', 'claimed_count' => '2', 'candidate_count' => '2', 'global_pending_count' => '8', 'active_batch_count' => '1' },
                     { 'observed_at' => '2026-09-16T12:01:00Z', 'claimed_count' => '1', 'candidate_count' => '1', 'global_pending_count' => '7', 'active_batch_count' => '1' },
                   ])
    rows = FollowImport::PacingBacktest::Input.load(
      transport: write_transport(File.join(dir, 't.csv'), [transport_row]),
      scenarios: File.join(dir, 's.json'),
      dispatch: path
    ).dispatch_passes

    result = described_class.new(rows, 3, 60).to_h

    expect(result['available']).to be true
    expect(result['active_minutes']).to eq 2
    expect(result['claims_per_minute']['max']).to eq 6
    expect(result['sum_of_claims_above_budget']).to eq 3
    expect(result['fraction_of_active_minutes_above_budget']).to eq 0.5
    expect(result).not_to have_key('reflowed_claims')
    expect(result).not_to have_key('cpu_safe')
    expect(result['cpu_db_note']).to include('must not be read as resource safety')
  end
end
