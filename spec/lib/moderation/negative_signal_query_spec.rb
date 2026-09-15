# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::NegativeSignalQuery do
  subject(:query) { described_class.new }

  let(:now)   { Time.now.utc }
  let(:actor) { Fabricate(:account, username: 'query_actor') }
  let(:peer)  { Fabricate(:account, username: 'query_peer') }

  def record_interaction(target, type, at, key)
    Moderation::EventRecorder.record_interaction(actor: actor, target: target, event_type: type, occurred_at: at, source_event_key: key)
  end

  def record_rejection(rejector, type, at, key)
    Moderation::EventRecorder.record_rejection(rejector: rejector, rejected: actor, event_type: type, occurred_at: at, source_event_key: key)
  end

  it 'separates raw, qualified, and unqualified counts by type' do
    record_interaction(peer, :follow, now - 40.minutes, 'q-i')
    record_rejection(peer, :follow_reject, now - 20.minutes, 'q-r')

    stranger = Fabricate(:account, username: 'query_stranger')
    Moderation::EventRecorder.record_rejection(
      rejector: stranger,
      rejected: actor,
      event_type: :follow_reject,
      occurred_at: now - 10.minutes,
      source_event_key: 'q-unlinked'
    )

    subject_row = ModerationSubject.find_by(account_id: actor.id)
    summary = query.summarize(subject_row, window_start: now - 24.hours, window_end: now)

    expect(summary['raw_events']).to eq 2
    expect(summary['qualified_events']).to eq 1
    expect(summary['unqualified_events']).to eq 1
    expect(summary.dig('by_type', 'follow_reject')).to eq('raw' => 2, 'qualified' => 1, 'unqualified' => 1)
    expect(summary.dig('by_type', 'block')).to eq('raw' => 0, 'qualified' => 0, 'unqualified' => 0)
  end

  it 'returns a stable empty shape when the subject is missing or has no events' do
    expect(query.summarize(nil, window_start: now - 24.hours, window_end: now)).to include(
      'raw_events' => 0,
      'qualified_events' => 0,
      'unqualified_events' => 0
    )
    expect(query.summarize(nil, window_start: now - 24.hours, window_end: now)['by_type'].keys).to match_array(described_class::REJECTION_TYPES)
  end
end
