# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require 'rails_helper'

RSpec.describe ExternalSubscriptionDeletion do
  def build(attributes = {})
    described_class.new({ user_id: 1, external_subscription_id: 1, external_source_id: 1, requested_at: Time.current }.merge(attributes))
  end

  it 'is preparing until the first count is known and has no percent or remaining' do
    deletion = build
    expect(deletion).to be_preparing
    expect(deletion.percent).to be_nil
    expect(deletion.remaining).to be_nil
    expect(deletion.eta_seconds).to be_nil
  end

  it 'derives remaining and percent from the deleted rows' do
    deletion = build(state: 'running', total_count: 200, deleted_count: 50)
    expect(deletion).not_to be_preparing
    expect(deletion.remaining).to eq 150
    expect(deletion.percent).to eq 25
  end

  it 'never reaches 100 percent before it is completed' do
    expect(build(state: 'running', total_count: 1000, deleted_count: 999).percent).to eq 99
    expect(build(state: 'running', total_count: 0, deleted_count: 0).percent).to eq 99
    expect(build(state: 'failed', total_count: 0, deleted_count: 0, next_run_at: 1.minute.from_now).percent).to eq 99
    expect(build(state: 'completed', total_count: 10, deleted_count: 10).percent).to eq 100
  end

  it 'clamps remaining at zero when more rows went than were counted' do
    expect(build(state: 'running', total_count: 5, deleted_count: 8).remaining).to eq 0
  end

  it 'gives an estimate only for a running job with an observed speed' do
    now = Time.current
    base = { state: 'running', total_count: 100, deleted_count: 40, started_at: now - 20, last_progress_at: now }
    expect(build(base).eta_seconds).to eq 30
    expect(build(base.merge(started_at: now - 1)).eta_seconds).to be_nil
    expect(build(base.merge(deleted_count: 0)).eta_seconds).to be_nil
    expect(build(base.merge(state: 'failed')).eta_seconds).to be_nil
    expect(build(base.merge(state: 'queued')).eta_seconds).to be_nil
    expect(build(base.merge(total_count: nil)).eta_seconds).to be_nil
  end

  it 'tells an automatic retry from a failure that waits for the owner' do
    waiting = build(state: 'failed', next_run_at: 5.minutes.from_now)
    exhausted = build(state: 'failed', next_run_at: nil)

    expect(waiting).to be_auto_retrying
    expect(waiting).to be_in_flight
    expect(waiting.retryable?).to be false
    expect(waiting).not_to be_terminal_failed
    expect(exhausted).not_to be_auto_retrying
    expect(exhausted).not_to be_in_flight
    expect(exhausted.retryable?).to be true
    expect(exhausted).to be_terminal_failed
    expect(build(state: 'queued')).to be_in_flight
    expect(build(state: 'completed')).not_to be_in_flight
  end

  it 'allows only the four states' do
    queued = build(state: 'queued')
    queued.valid?
    expect(queued.errors[:state]).to be_empty
    other = build(state: 'deleting')
    other.valid?
    expect(other.errors[:state]).not_to be_empty
  end
end

# rubocop:enable Metrics/BlockLength
