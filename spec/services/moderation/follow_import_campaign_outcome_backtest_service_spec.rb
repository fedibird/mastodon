# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Moderation::FollowImportCampaignOutcomeBacktestService do
  let(:t0) { Time.utc(2026, 9, 21, 12, 0, 0) }
  let(:ended_at) { t0 + 10.minutes }
  let(:observation_end) { t0 + 12.hours }
  let(:horizons) do
    {
      '1h'  => 1.hour,
      '6h'  => 6.hours,
      '24h' => 24.hours,
      '7d'  => 7.days,
    }
  end
  let(:importer) { Fabricate(:moderation_subject) }
  let(:historical) { Fabricate(:moderation_subject) }
  let(:target_a) { Fabricate(:moderation_subject) }
  let(:target_b) { Fabricate(:moderation_subject) }
  let(:target_c) { Fabricate(:moderation_subject) }

  def feature_campaign(subject, **attrs)
    started = attrs.fetch(:started_at, t0)
    ended = attrs.fetch(:ended_at, ended_at)
    {
      'campaign_index' => attrs.fetch(:index, 0),
      'campaign_key' => "#{subject.id}:#{started.to_i}",
      'subject_id' => subject.id,
      'started_at' => started,
      'ended_at' => ended,
      'as_of' => started,
      'matching_snapshot_count' => attrs.fetch(:matching_snapshot_count, 1),
      'cross_subject' => {
        'matching_snapshot_count' => attrs.fetch(:matching_snapshot_count, 1),
        'best_match' => attrs[:best_match],
      },
      'same_subject' => { 'matching_snapshot_count' => 0, 'best_match' => nil },
    }
  end

  def analysis_for(campaigns)
    {
      'generated_at'                         => t0.iso8601,
      'max_gap_seconds'                      => 30.minutes.to_f,
      'campaign_count'                       => campaigns.size,
      'subject_count'                        => campaigns.map { |row| row['subject_id'] }.uniq.size,
      'campaigns_with_any_overlap'           => campaigns.count { |row| row['matching_snapshot_count'].to_i.positive? },
      'campaigns_with_same_subject_overlap'  => 0,
      'campaigns_with_cross_subject_overlap' => campaigns.count { |row| row.dig('cross_subject', 'matching_snapshot_count').to_i.positive? },
      'coverage'                             => { 'complete' => 1, 'incomplete' => 0, 'unknown' => 0 },
      'distributions'                        => { 'cross_subject' => { 'overlap_count' => { 'n' => 1 } } },
      'campaigns'                            => campaigns,
      'elapsed_seconds'                      => 0.01,
    }
  end

  def backtest(campaigns, **attrs)
    fake = instance_double(Moderation::FollowImportCampaignNegativeTargetOverlapService)
    allow(fake).to receive(:call).and_return(analysis_for(campaigns))
    described_class.new(campaign_service: fake).call(
      [],
      max_gap: attrs.fetch(:max_gap, 30.minutes),
      observation_end: attrs.fetch(:observation_end, observation_end),
      horizons: attrs.fetch(:horizons, horizons)
    )
  end

  def create_action(subject, action_type:, at:)
    Fabricate(:moderation_action, subject: subject, action_type: action_type, performed_at: at)
  end

  def create_batch(subject, targets:, at: t0)
    batch = FollowImportBatch.create!(
      subject: subject,
      imported_at: at,
      mode: :merge,
      target_count: targets.size,
      resolved_target_count: targets.size,
      unresolved_target_count: 0
    )
    targets.each_with_index do |target, position|
      batch.targets.create!(target_subject: target, position: position)
    end
    batch
  end

  def create_moderated_snapshot(subject, linked_ids:, performed_at:)
    snapshot = Fabricate(
      :moderation_evidence_snapshot,
      subject: subject,
      summary: { 'linked_negative_target_count' => linked_ids.size },
      fingerprint: { 'linked_negative_target_subject_ids' => linked_ids }
    )
    Fabricate(
      :moderation_action,
      subject: subject,
      evidence_snapshot: snapshot,
      action_type: :suspend,
      performed_at: performed_at
    )
    snapshot
  end

  def ledger_counts
    [
      ModerationSubject.count,
      ModerationInteractionEvent.count,
      ModerationRejectionEvent.count,
      ModerationAction.count,
      ModerationEvidenceSnapshot.count,
      FollowImportBatch.count,
      FollowImportTarget.count,
      Follow.count,
      Block.count,
      Mute.count,
    ]
  end

  describe 'temporal classification' do
    let(:campaign) { feature_campaign(importer, best_match: { 'overlap_count' => 3, 'jaccard' => 0.5 }) }

    it 'reports a prior action only as prior context' do
      create_action(importer, action_type: :warn, at: t0 - 2.hours)
      outcome = backtest([campaign])['campaigns'].first['outcome']

      expect(outcome['prior_action_count']).to eq 1
      expect(outcome['prior_action_types']).to eq ['warn']
      expect(outcome['latest_prior_action_at']).to eq t0 - 2.hours
      expect(outcome['during_campaign_action_count']).to eq 0
      expect(outcome['post_campaign_action_count']).to eq 0
      expect(outcome['first_post_campaign_action']).to be_nil
    end

    it 'reports an action between start and end as during-campaign, not a post outcome' do
      create_action(importer, action_type: :limit, at: t0 + 5.minutes)
      outcome = backtest([campaign])['campaigns'].first['outcome']

      expect(outcome['during_campaign_action_count']).to eq 1
      expect(outcome['during_campaign_action_types']).to eq ['limit']
      expect(outcome['first_during_campaign_action_at']).to eq t0 + 5.minutes
      expect(outcome['post_campaign_action_count']).to eq 0
      expect(outcome['first_post_campaign_action']).to be_nil
    end

    it 'reports an action after campaign end as a post-campaign outcome' do
      action = create_action(importer, action_type: :suspend, at: ended_at + 5.minutes)
      outcome = backtest([campaign])['campaigns'].first['outcome']
      first = outcome['first_post_campaign_action']

      expect(outcome['post_campaign_action_count']).to eq 1
      expect(outcome['post_campaign_action_types']).to eq ['suspend']
      expect(first['action_id']).to eq action.id
      expect(first['action_type']).to eq 'suspend'
      expect(first['performed_at']).to eq ended_at + 5.minutes
      expect(first['seconds_after_campaign_end']).to eq 5.minutes.to_f
      expect(outcome['during_campaign_action_count']).to eq 0
    end

    it 'excludes an action after observation_end' do
      create_action(importer, action_type: :suspend, at: observation_end + 1.minute)
      outcome = backtest([campaign])['campaigns'].first['outcome']

      expect(outcome['post_campaign_action_count']).to eq 0
      expect(outcome['first_post_campaign_action']).to be_nil
    end

    it 'keeps the first action per type deterministic when several exist' do
      first_warn = create_action(importer, action_type: :warn, at: ended_at + 2.minutes)
      create_action(importer, action_type: :warn, at: ended_at + 8.minutes)
      first_suspend = create_action(importer, action_type: :suspend, at: ended_at + 9.minutes)

      outcome = backtest([campaign])['campaigns'].first['outcome']
      by_type = outcome['first_post_action_by_type']

      expect(outcome['first_post_campaign_action']['action_id']).to eq first_warn.id
      expect(by_type['warn']['action_id']).to eq first_warn.id
      expect(by_type['suspend']['action_id']).to eq first_suspend.id
      expect(by_type['limit']).to be_nil
      expect(outcome['post_campaign_action_count']).to eq 3
      expect(outcome['post_campaign_action_types']).to eq %w(warn suspend)
    end
  end

  describe 'horizon reach and right censoring' do
    let(:campaign) { feature_campaign(importer) }

    it 'treats no action after a fully elapsed horizon as an eligible non-reacher' do
      summary = backtest([campaign])['outcomes']['suspend']['1h']

      expect(summary['campaigns_reached']).to eq 0
      expect(summary['campaigns_eligible']).to eq 1
      expect(summary['campaigns_censored']).to eq 0
      expect(summary['reach_rate']).to eq 0.0
    end

    it 'censors a non-reached campaign whose horizon has not fully elapsed' do
      summary = backtest([campaign], observation_end: ended_at + 30.minutes)['outcomes']['suspend']['1h']

      expect(summary['campaigns_reached']).to eq 0
      expect(summary['campaigns_eligible']).to eq 0
      expect(summary['campaigns_censored']).to eq 1
    end

    it 'counts an observed action within the horizon as reached and eligible even if the horizon has not elapsed' do
      create_action(importer, action_type: :suspend, at: ended_at + 5.minutes)
      summary = backtest([campaign], observation_end: ended_at + 30.minutes)['outcomes']['suspend']['1h']

      expect(summary['campaigns_reached']).to eq 1
      expect(summary['campaigns_eligible']).to eq 1
      expect(summary['campaigns_censored']).to eq 0
      expect(summary['reach_rate']).to eq 1.0
      expect(summary['time_to_first_action_seconds']['min']).to eq 5.minutes.to_f
    end

    it 'counts an action outside 1h but inside 6h only for the 6h and longer windows' do
      create_action(importer, action_type: :suspend, at: ended_at + 5.hours)
      result = backtest([campaign])

      expect(result['outcomes']['suspend']['1h']['campaigns_reached']).to eq 0
      expect(result['outcomes']['suspend']['1h']['campaigns_eligible']).to eq 1
      expect(result['outcomes']['suspend']['6h']['campaigns_reached']).to eq 1
      expect(result['outcomes']['suspend']['24h']['campaigns_reached']).to eq 1
      expect(result['outcomes']['suspend']['7d']['campaigns_reached']).to eq 1
    end

    it 'keeps individual action_type summaries separate from any_action' do
      create_action(importer, action_type: :warn, at: ended_at + 3.minutes)
      result = backtest([campaign])

      expect(result['outcomes']['any_action']['1h']['campaigns_reached']).to eq 1
      expect(result['outcomes']['warn']['1h']['campaigns_reached']).to eq 1
      expect(result['outcomes']['suspend']['1h']['campaigns_reached']).to eq 0
      expect(result['outcomes']['suspend']['1h']['campaigns_eligible']).to eq 1
    end
  end

  describe 'repeated campaigns for one subject' do
    it 'classifies actions against each campaign end time' do
      first = feature_campaign(importer, index: 0, started_at: t0, ended_at: t0 + 5.minutes)
      second = feature_campaign(importer, index: 1, started_at: t0 + 40.minutes, ended_at: t0 + 50.minutes)
      create_action(importer, action_type: :suspend, at: t0 + 10.minutes)

      result = backtest([first, second])
      first_outcome = result['campaigns'][0]['outcome']
      second_outcome = result['campaigns'][1]['outcome']

      expect(first_outcome['post_campaign_action_count']).to eq 1
      expect(first_outcome['first_post_campaign_action']['seconds_after_campaign_end']).to eq 5.minutes.to_f
      expect(second_outcome['prior_action_count']).to eq 1
      expect(second_outcome['post_campaign_action_count']).to eq 0
    end
  end

  describe 'feature preservation' do
    it 'keeps the #143 campaign feature row unchanged aside from the added outcome block' do
      best = { 'overlap_count' => 231, 'stored_negative_containment' => 0.6507, 'jaccard' => 0.12, 'snapshot_id' => 99 }
      campaign = feature_campaign(importer, matching_snapshot_count: 1, best_match: best)
      create_action(importer, action_type: :suspend, at: ended_at + 4.minutes)

      row = backtest([campaign])['campaigns'].first
      expect(row['as_of']).to eq t0
      expect(row['matching_snapshot_count']).to eq 1
      expect(row.dig('cross_subject', 'best_match')).to eq best
      expect(row['outcome']['post_campaign_action_types']).to eq ['suspend']
      expect(row['outcome']).to_not have_key('severe')
    end

    it 'does not pass observation_end into campaign overlap as_of' do
      fake = instance_double(Moderation::FollowImportCampaignNegativeTargetOverlapService)
      expect(fake).to receive(:call).with([], max_gap: 15.minutes, now: observation_end).and_return(analysis_for([]))

      described_class.new(campaign_service: fake).call(
        [],
        max_gap: 15.minutes,
        observation_end: observation_end,
        horizons: horizons
      )
    end
  end

  describe 'empty cohort' do
    it 'returns a stable zero/empty shape' do
      result = described_class.new.call([], observation_end: observation_end, horizons: horizons)

      expect(result['observation_end']).to eq observation_end
      expect(result['campaign_count']).to eq 0
      expect(result['batches_excluded_after_observation_end']).to eq 0
      expect(result['campaigns']).to eq []
      expect(result['horizons_seconds']['1h']).to eq 1.hour.to_f
      expect(result['outcomes']['suspend']['1h']['campaigns_reached']).to eq 0
      expect(result['outcomes']['suspend']['1h']['campaigns_censored']).to eq 0
      expect(result['elapsed_seconds']).to be >= 0
    end
  end

  describe 'no-future-leakage batch cutoff' do
    let(:cutoff) { Time.utc(2026, 9, 21, 12, 0, 0) }

    it 'keeps campaign grouping, union, and overlap on batches imported at or before observation_end' do
      visible = create_batch(importer, targets: [target_a, target_b], at: cutoff - 1.hour)
      at_cutoff = create_batch(importer, targets: [target_a], at: cutoff)
      future = create_batch(importer, targets: [target_c], at: cutoff + 30.minutes)
      create_moderated_snapshot(
        historical,
        linked_ids: [target_a.id, target_b.id, target_c.id],
        performed_at: cutoff - 1.day
      )

      result = described_class.new.call(
        FollowImportBatch.where(subject_id: importer.id),
        max_gap: 2.hours,
        observation_end: cutoff,
        horizons: horizons
      )
      campaign = result['campaigns'].first
      match = campaign.dig('cross_subject', 'best_match')

      expect(result['campaign_count']).to eq 1
      expect(result['batches_excluded_after_observation_end']).to eq 1
      expect(campaign['batch_ids']).to eq [visible.id, at_cutoff.id]
      expect(campaign['batch_ids']).to_not include(future.id)
      expect(campaign['ended_at']).to eq cutoff
      expect(campaign['comparable_unique_target_count']).to eq 2
      expect(match['overlap_count']).to eq 2
    end

    it 'does not count a later same-subject batch as a second campaign after observation_end' do
      visible = create_batch(importer, targets: [target_a], at: cutoff - 1.hour)
      create_batch(importer, targets: [target_b], at: cutoff + 2.hours)

      result = described_class.new.call(
        FollowImportBatch.where(subject_id: importer.id).to_a,
        max_gap: 30.minutes,
        observation_end: cutoff,
        horizons: horizons
      )
      campaign = result['campaigns'].first

      expect(result['campaign_count']).to eq 1
      expect(result['batches_excluded_after_observation_end']).to eq 1
      expect(campaign['batch_ids']).to eq [visible.id]
      expect(campaign['ended_at']).to eq cutoff - 1.hour
      expect(campaign['comparable_unique_target_count']).to eq 1
    end
  end

  describe 'production-style regression and read-only' do
    it 'keeps overlap on the campaign-start baseline and records a later suspend only as a post outcome' do
      create_batch(importer, targets: [target_a, target_b, target_c], at: t0)
      create_batch(importer, targets: [target_a], at: t0 + 90.seconds)
      past = create_moderated_snapshot(historical, linked_ids: [target_a.id, target_b.id], performed_at: t0 - 1.day)
      later_snapshot = create_moderated_snapshot(importer, linked_ids: [target_a.id, target_b.id, target_c.id], performed_at: t0 + 90.seconds + 8.minutes)
      later_action = later_snapshot.moderation_actions.order(:id).first

      result = nil
      expect do
        result = described_class.new.call(
          FollowImportBatch.where(subject_id: importer.id),
          max_gap: 30.minutes,
          observation_end: t0 + 12.hours,
          horizons: horizons
        )
      end.to_not(change { ledger_counts })

      campaign = result['campaigns'].first
      match = campaign.dig('cross_subject', 'best_match')
      outcome = campaign['outcome']

      expect(campaign['as_of']).to eq t0
      expect(match['snapshot_id']).to eq past.id
      expect(match['overlap_count']).to eq 2
      expect(match['snapshot_id']).to_not eq later_snapshot.id
      expect(outcome['during_campaign_action_count']).to eq 0
      expect(outcome['post_campaign_action_types']).to eq ['suspend']
      expect(outcome['first_post_campaign_action']['action_id']).to eq later_action.id
      expect(result['outcomes']['suspend']['1h']['campaigns_reached']).to eq 1
      expect(result).to_not have_key('score')
      expect(result).to_not have_key('recommendation')
    end
  end
end
# rubocop:enable Metrics/BlockLength
