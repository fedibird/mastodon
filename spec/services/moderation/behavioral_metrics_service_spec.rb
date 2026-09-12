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

  context 'with a primary contact/rejection scenario' do
    # Interactions (actor -> target):
    #   b follow  @ -120m,  c follow @ -50m,  d mention @ -30m,  g follow @ -20m
    # Rejections (responder -> actor):
    #   b block         @ -118m (after the follow  -> linked)
    #   c follow_reject @ -48m  (after the follow  -> linked; c is in the follow cohort)
    #   g block         @ -25m  (BEFORE actor's -20m follow -> contacted but not linked = correlated)
    before do
      record_interaction(b, :follow, now - 120.minutes, 'i-b')
      record_interaction(c, :follow, now - 50.minutes, 'i-c')
      record_interaction(d, :mention, now - 30.minutes, 'i-d')
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

      it 'counts rejections received (raw) and classifies the contacted cohort' do
        expect(metrics['rejections_received_total']).to eq 3
        expect(metrics['blocks_received']).to eq 2
        expect(metrics['follow_rejects_received']).to eq 1
        expect(metrics['unique_negative_responders']).to eq 3
        expect(metrics['linked_negative_responders']).to eq 2
        expect(metrics['correlated_negative_responders']).to eq 1
      end

      it 'computes cohort-aligned rates as raw floats' do
        # (linked + correlated) / unique in-window targets = 3/4
        expect(metrics['negative_response_rate']).to eq 0.75
        expect(metrics['linked_negative_rate']).to eq 0.5
        # follow_rejects from followed targets (c) / followed targets (b,c,g) = 1/3
        expect(metrics['follow_reject_rate']).to be_within(1e-9).of(1.0 / 3)
      end

      it 'counts genuinely-new targets and follows after the first negative signal' do
        expect(metrics['first_negative_signal_at']).to eq((now - 118.minutes).iso8601)
        # first signal @ -118m; c(-50), d(-30), g(-20) contacted after with no prior; b(-120) is before
        expect(metrics['new_targets_after_first_negative_signal']).to eq 3
        # follows after -118m: c and g (d is a mention)
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

      it 'keeps rates cohort-aligned within the window' do
        # (c linked + g correlated) / {c,d,g} = 2/3
        expect(metrics['negative_response_rate']).to be_within(1e-9).of(2.0 / 3)
        expect(metrics['linked_negative_rate']).to be_within(1e-9).of(1.0 / 3)
        # c follow_reject / followed {c,g} = 1/2
        expect(metrics['follow_reject_rate']).to eq 0.5
      end

      it 'measures continuation relative to the first in-window negative signal' do
        expect(metrics['first_negative_signal_at']).to eq((now - 48.minutes).iso8601)
        # first in-window signal @ -48m; d(-30) and g(-20) contacted after, both new; c(-50) is before
        expect(metrics['new_targets_after_first_negative_signal']).to eq 2
        # follows after -48m within window: g only (d is a mention, c is before)
        expect(metrics['follows_after_first_negative_signal']).to eq 1
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
  end

  describe 'genuinely-new-target semantics' do
    # actor contacted x BEFORE the first negative signal and re-contacts it
    # after; x must NOT be counted as a new target after the signal.
    let(:x) { Fabricate(:account, username: 'recontacted_x') }
    let(:y) { Fabricate(:account, username: 'fresh_y') }

    before do
      record_interaction(x, :follow, now - 40.minutes, 'nx-1')       # prior contact
      record_rejection(b, :block, now - 30.minutes, 'nx-r')          # first negative signal
      record_interaction(x, :mention, now - 20.minutes, 'nx-2')      # re-contact (not new)
      record_interaction(y, :follow, now - 10.minutes, 'nx-3')       # genuinely new
    end

    it 'excludes re-contacted targets and counts only targets with no prior contact' do
      metrics = service.call(actor, now: now).dig('windows', '1h')

      expect(metrics['first_negative_signal_at']).to eq((now - 30.minutes).iso8601)
      # after the signal: x (re-contacted, prior at -40m) and y (new). Only y counts.
      expect(metrics['new_targets_after_first_negative_signal']).to eq 1
    end
  end

  describe 'rate cohort boundaries' do
    let(:h) { Fabricate(:account, username: 'boundary_h') }
    let(:k) { Fabricate(:account, username: 'boundary_k') }

    # h is contacted just OUTSIDE the 1h window but rejects INSIDE it; k is
    # contacted and rejects inside. A naive rate (raw responders / in-window
    # targets) would be 2/1 = 2.0. The cohort-aligned rate must stay <= 1.
    before do
      record_interaction(h, :follow, now - 70.minutes, 'b-i-h')
      record_interaction(k, :follow, now - 10.minutes, 'b-i-k')
      record_rejection(h, :block, now - 30.minutes, 'b-r-h')
      record_rejection(k, :block, now - 5.minutes, 'b-r-k')
    end

    it 'does not let an out-of-window contact inflate an in-window rate above 1' do
      metrics = service.call(actor, now: now).dig('windows', '1h')

      # Raw event-window counts are preserved: both h and k rejected in-window,
      # but only k was contacted in-window.
      expect(metrics['unique_negative_responders']).to eq 2
      expect(metrics['unique_targets']).to eq 1

      # Cohort-aligned rate counts only k (contacted in-window and linked): 1/1.
      expect(metrics['linked_negative_responders']).to eq 1
      expect(metrics['negative_response_rate']).to eq 1.0
      expect(metrics['negative_response_rate']).to be <= 1.0
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

    it 'summarizes batches and the unresolved-target ratio (not the design unknown ratio)' do
      context = service.call(actor, now: now)['follow_import_context']

      expect(context['batch_count']).to eq 1
      expect(context['target_total']).to eq 10
      expect(context['unresolved_target_total']).to eq 3
      expect(context['unresolved_target_ratio']).to eq 0.3
      expect(context).to_not have_key('unknown_target_ratio')
      expect(context['prior_relationship_known_targets']).to eq 1
      expect(context['min_account_age_seconds_at_import']).to eq 131
      expect(context['migration_evidence']).to include('weak' => 1, 'none' => 0)
    end
  end

  describe 'read-only guarantees' do
    it 'resolves the subject from an account without writing' do
      record_interaction(b, :follow, now - 5.minutes, 'ro-1')

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
