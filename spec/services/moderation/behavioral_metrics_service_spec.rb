# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::BehavioralMetricsService do
  subject(:service) { described_class.new }

  let(:now)   { Time.now.utc }
  let(:actor) { Fabricate(:account, username: 'actor') }
  let(:b)     { Fabricate(:account, username: 'target_b') }
  let(:c)     { Fabricate(:account, username: 'target_c') }
  let(:d)     { Fabricate(:account, username: 'target_d') }
  let(:g)     { Fabricate(:account, username: 'responder_g') }

  def record_interaction(target, type, at, key)
    Moderation::EventRecorder.record_interaction(actor: actor, target: target, event_type: type, occurred_at: at, source_event_key: key)
  end

  def record_rejection(rejector, type, at, key)
    Moderation::EventRecorder.record_rejection(rejector: rejector, rejected: actor, event_type: type, occurred_at: at, source_event_key: key)
  end

  # Interactions (actor -> target):
  #   b follow  @ -120m,  c mention @ -50m,  d follow @ -30m,  g follow @ -20m
  # Rejections (responder -> actor):
  #   b block   @ -118m (after the follow  -> linked)
  #   c reject  @ -48m  (after the mention -> linked)
  #   g block   @ -25m  (BEFORE actor's -20m follow -> contacted but not linked = correlated)
  before do
    record_interaction(b, :follow, now - 120.minutes, 'i-b')
    record_interaction(c, :mention, now - 50.minutes, 'i-c')
    record_interaction(d, :follow, now - 30.minutes, 'i-d')
    record_interaction(g, :follow, now - 20.minutes, 'i-g')

    record_rejection(b, :block, now - 118.minutes, 'r-b')
    record_rejection(c, :follow_reject, now - 48.minutes, 'r-c')
    record_rejection(g, :block, now - 25.minutes, 'r-g')
  end

  describe 'the 24h window' do
    let(:metrics) { service.call(actor, now: now).dig('windows', '24h') }

    it 'counts contacts, unique targets and follows' do
      expect(metrics['contacts_total']).to eq 4
      expect(metrics['unique_targets']).to eq 4
      expect(metrics['follows']).to eq 3
      expect(metrics['interactions_by_type']).to include('follow' => 3, 'mention' => 1)
    end

    it 'counts rejections received and classifies responders' do
      expect(metrics['rejections_received_total']).to eq 3
      expect(metrics['blocks_received']).to eq 2
      expect(metrics['follow_rejects_received']).to eq 1
      expect(metrics['unique_negative_responders']).to eq 3
      expect(metrics['linked_negative_responders']).to eq 2
      expect(metrics['correlated_negative_responders']).to eq 1
    end

    it 'computes rates guarded against zero denominators' do
      expect(metrics['negative_response_rate']).to eq 0.75
      expect(metrics['linked_negative_rate']).to eq 0.5
      expect(metrics['follow_reject_rate']).to eq 0.3333
    end

    it 'measures contact continuation after the first negative signal' do
      expect(metrics['first_negative_signal_at']).to eq((now - 118.minutes).iso8601)
      expect(metrics['new_targets_after_first_negative_signal']).to eq 3
      expect(metrics['follows_after_first_negative_signal']).to eq 2
    end
  end

  describe 'the 1h window' do
    let(:metrics) { service.call(actor, now: now).dig('windows', '1h') }

    it 'excludes events older than the window' do
      expect(metrics['contacts_total']).to eq 3
      expect(metrics['unique_targets']).to eq 3
      expect(metrics['follows']).to eq 2
      expect(metrics['rejections_received_total']).to eq 2
      expect(metrics['linked_negative_responders']).to eq 1
      expect(metrics['correlated_negative_responders']).to eq 1
    end

    it 'measures continuation relative to the first in-window negative signal' do
      expect(metrics['first_negative_signal_at']).to eq((now - 48.minutes).iso8601)
      expect(metrics['new_targets_after_first_negative_signal']).to eq 2
      expect(metrics['follows_after_first_negative_signal']).to eq 2
    end
  end

  describe 'lifetime metrics' do
    it 'has no lower time bound' do
      lifetime = service.call(actor, now: now)['lifetime']
      expect(lifetime['window_start']).to be_nil
      expect(lifetime['contacts_total']).to eq 4
      expect(lifetime['unique_negative_responders']).to eq 3
    end
  end

  describe 'follow-import context' do
    let!(:batch) do
      FollowImportBatch.create!(
        subject: ModerationSubject.for_account!(actor),
        imported_at: now - 10.minutes,
        mode: :merge,
        target_count: 10,
        resolved_target_count: 7,
        unresolved_target_count: 3,
        account_age_seconds: 131,
        migration_evidence: :weak
      )
    end

    before do
      batch.targets.create!(target_subject: ModerationSubject.for_account!(b), position: 0, prior_relationship_state: { 'following' => true })
      batch.targets.create!(target_subject: ModerationSubject.for_account!(c), position: 1, prior_relationship_state: { 'following' => false })
      batch.targets.create!(target_key_hash: 'deadbeef', position: 2)
    end

    it 'summarizes batches and the unknown-target ratio' do
      context = service.call(actor, now: now)['follow_import_context']

      expect(context['batch_count']).to eq 1
      expect(context['target_total']).to eq 10
      expect(context['unresolved_target_total']).to eq 3
      expect(context['unknown_target_ratio']).to eq 0.3
      expect(context['prior_relationship_known_targets']).to eq 1
      expect(context['min_account_age_seconds_at_import']).to eq 131
      expect(context['migration_evidence']).to include('weak' => 1, 'none' => 0)
    end
  end

  describe 'read-only guarantees' do
    it 'resolves the subject from an account without writing' do
      metrics = service.call(actor, now: now)
      expect(metrics['subject_id']).to eq ModerationSubject.find_by(account_id: actor.id).id
      expect(metrics['account_id']).to eq actor.id
    end

    it 'never creates a ModerationSubject for an account with no ledger history' do
      fresh = Fabricate(:account, username: 'never_seen')

      result = nil
      expect { result = service.call(fresh, now: now) }.to_not change(ModerationSubject, :count)

      expect(result['subject_id']).to be_nil
      expect(result.dig('windows', '24h', 'contacts_total')).to eq 0
      expect(result['follow_import_context']['batch_count']).to eq 0
    end
  end
end
