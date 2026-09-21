# frozen_string_literal: true

# Offline calibration backtest: join later ModerationAction rows to PR #143
# campaign feature rows without feeding those outcomes back into overlap.
#
# observation_end is the backtest cutoff. Caller-supplied batches are
# restricted to imported_at <= observation_end before the campaign service
# groups them. A later batch is not part of campaign union, ended_at,
# grouping, or overlap features. ModerationAction rows are likewise
# limited to performed_at <= observation_end.
#
# The campaign service freezes historical linked-negative evidence at
# campaign.started_at. This service does not change that. It only classifies
# actions on the *current campaign subject*:
#
#   * prior:    performed_at <= started_at
#   * during:   started_at < performed_at <= ended_at   (not an outcome label)
#   * post:     ended_at < performed_at <= observation_end
#
# Post-campaign actions are the valid completed-campaign outcomes. Actions
# after observation_end are invisible. A later action is an observed outcome,
# not proof that overlap caused it, and not identity inference.
#
# Horizon reach uses right-censoring: a campaign that has not been observed
# for the full horizon, and has no qualifying post action yet, is excluded
# from the denominator. A reached campaign is eligible even if the horizon
# has not fully elapsed.
#
# Read-only. Caller supplies batches. max_gap remains an injectable grouping
# heuristic, not a risk threshold. No score, recommendation, gate, or writes.
#
# Console / rails runner:
#
#   batches = FollowImportBatch.where(imported_at: 10.days.ago..Time.current)
#   result = Moderation::FollowImportCampaignOutcomeBacktestService.new.call(
#     batches,
#     max_gap: 30.minutes,
#     observation_end: Time.now.utc
#   )
#   puts JSON.pretty_generate(result)
module Moderation
  class FollowImportCampaignOutcomeBacktestService
    DEFAULT_MAX_GAP = 30.minutes
    DEFAULT_HORIZONS = {
      '1h'  => 1.hour,
      '6h'  => 6.hours,
      '24h' => 24.hours,
      '7d'  => 7.days,
    }.freeze
    ACTION_TYPES = %w(warn limit freeze suspend delete other).freeze
    PERCENTILES = [10, 25, 50, 75, 90, 95, 99].freeze

    def initialize(campaign_service: Moderation::FollowImportCampaignNegativeTargetOverlapService.new)
      @campaign_service = campaign_service
    end

    def call(batches, max_gap: DEFAULT_MAX_GAP, observation_end: Time.now.utc, horizons: DEFAULT_HORIZONS)
      started_clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      visible, excluded = restrict_batches(batches, observation_end)
      analysis = @campaign_service.call(visible, max_gap: max_gap, now: observation_end)
      campaigns = Array(analysis['campaigns'])
      actions_by_subject = preload_actions(campaigns, observation_end)
      decorated = decorate_campaigns(campaigns, actions_by_subject, observation_end)

      {
        'generated_at'                         => observation_end.iso8601,
        'observation_end'                      => observation_end,
        'max_gap_seconds'                      => analysis['max_gap_seconds'],
        'horizons_seconds'                     => horizon_seconds(horizons),
        'batches_excluded_after_observation_end' => excluded,
        'campaign_count'                       => analysis['campaign_count'],
        'subject_count'                        => analysis['subject_count'],
        'campaigns_with_any_overlap'           => analysis['campaigns_with_any_overlap'],
        'campaigns_with_same_subject_overlap'  => analysis['campaigns_with_same_subject_overlap'],
        'campaigns_with_cross_subject_overlap' => analysis['campaigns_with_cross_subject_overlap'],
        'coverage'                             => analysis['coverage'],
        'distributions'                        => analysis['distributions'],
        'outcomes'                             => summarize_outcomes(decorated, actions_by_subject, horizons, observation_end),
        'campaigns'                            => decorated,
        'elapsed_seconds'                      => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_clock,
      }
    end

    private

    def horizon_seconds(horizons)
      horizons.each_with_object({}) do |(name, duration), memo|
        memo[name] = duration.to_f
      end
    end

    def restrict_batches(batches, observation_end)
      if batches.is_a?(ActiveRecord::Relation)
        [
          batches.where('imported_at <= ?', observation_end),
          batches.where('imported_at > ?', observation_end).count,
        ]
      else
        visible = []
        excluded = 0
        Array(batches).each do |batch|
          if batch.imported_at <= observation_end
            visible << batch
          else
            excluded += 1
          end
        end
        [visible, excluded]
      end
    end

    def preload_actions(campaigns, observation_end)
      subject_ids = campaigns.map { |campaign| campaign['subject_id'] }.uniq.compact
      return {} if subject_ids.empty?

      ModerationAction
        .where(subject_id: subject_ids)
        .where('performed_at <= ?', observation_end)
        .order(:subject_id, :performed_at, :id)
        .group_by(&:subject_id)
    end

    def decorate_campaigns(campaigns, actions_by_subject, observation_end)
      campaigns.map do |campaign|
        actions = actions_by_subject[campaign['subject_id']] || []
        campaign.merge('outcome' => outcome_block(campaign, actions, observation_end))
      end
    end

    def outcome_block(campaign, actions, observation_end)
      prior, during, post = classify_actions(campaign, actions)
      ended_at = campaign['ended_at']

      {
        'observation_end'                 => observation_end,
        'prior_action_count'              => prior.size,
        'prior_action_types'              => unique_action_types(prior),
        'latest_prior_action_at'          => prior.last&.performed_at,
        'during_campaign_action_count'    => during.size,
        'during_campaign_action_types'    => unique_action_types(during),
        'first_during_campaign_action_at' => during.first&.performed_at,
        'post_campaign_action_count'      => post.size,
        'post_campaign_action_types'      => unique_action_types(post),
        'first_post_campaign_action'      => action_timing(post.first, ended_at),
        'first_post_action_by_type'       => first_post_by_type(post, ended_at),
      }
    end

    def classify_actions(campaign, actions)
      started_at = campaign['started_at']
      ended_at = campaign['ended_at']
      prior = []
      during = []
      post = []

      actions.each do |action|
        at = action.performed_at
        if at <= started_at
          prior << action
        elsif at <= ended_at
          during << action
        else
          post << action
        end
      end

      [prior, during, post]
    end

    def unique_action_types(actions)
      types = []
      actions.each do |action|
        types << action.action_type unless types.include?(action.action_type)
      end
      types
    end

    def first_post_by_type(post, ended_at)
      ACTION_TYPES.index_with do |type|
        action_timing(post.find { |action| action.action_type == type }, ended_at)
      end
    end

    def action_timing(action, ended_at)
      return if action.nil?

      {
        'action_id'                    => action.id,
        'action_type'                  => action.action_type,
        'performed_at'                 => action.performed_at,
        'seconds_after_campaign_end'   => (action.performed_at - ended_at).to_f,
      }
    end

    def summarize_outcomes(campaigns, actions_by_subject, horizons, observation_end)
      keys = ['any_action'] + ACTION_TYPES
      buckets = keys.index_with { horizons.keys.index_with { empty_bucket } }

      campaigns.each do |campaign|
        _prior, _during, post = classify_actions(campaign, actions_by_subject[campaign['subject_id']] || [])
        record_campaign_horizons(buckets, campaign, post, horizons, observation_end)
      end

      keys.index_with do |key|
        horizons.keys.index_with { |name| horizon_summary(buckets[key][name]) }
      end
    end

    def record_campaign_horizons(buckets, campaign, post, horizons, observation_end)
      horizons.each do |name, duration|
        record_horizon(buckets['any_action'][name], first_within_horizon(post, campaign['ended_at'], duration), campaign['ended_at'], observation_end, duration)

        ACTION_TYPES.each do |type|
          typed = post.select { |action| action.action_type == type }
          record_horizon(buckets[type][name], first_within_horizon(typed, campaign['ended_at'], duration), campaign['ended_at'], observation_end, duration)
        end
      end
    end

    def first_within_horizon(actions, ended_at, horizon)
      deadline = ended_at + horizon
      actions.find { |action| action.performed_at <= deadline }
    end

    def record_horizon(bucket, first, ended_at, observation_end, horizon)
      if first
        bucket[:reached] += 1
        bucket[:eligible] += 1
        bucket[:times] << (first.performed_at - ended_at).to_f
      elsif ended_at + horizon <= observation_end
        bucket[:eligible] += 1
      else
        bucket[:censored] += 1
      end
    end

    def empty_bucket
      { reached: 0, eligible: 0, censored: 0, times: [] }
    end

    def horizon_summary(bucket)
      {
        'campaigns_reached'              => bucket[:reached],
        'campaigns_eligible'             => bucket[:eligible],
        'campaigns_censored'             => bucket[:censored],
        'reach_rate'                     => ratio(bucket[:reached], bucket[:eligible]),
        'time_to_first_action_seconds'   => distribution(bucket[:times]),
      }
    end

    def distribution(values)
      return empty_distribution if values.empty?

      sorted = values.sort
      {
        'n'           => sorted.size,
        'min'         => sorted.first,
        'max'         => sorted.last,
        'mean'        => sorted.sum.to_f / sorted.size,
        'percentiles' => PERCENTILES.index_with { |percent| percentile(sorted, percent) },
      }
    end

    def empty_distribution
      {
        'n'           => 0,
        'min'         => nil,
        'max'         => nil,
        'mean'        => nil,
        'percentiles' => PERCENTILES.index_with { nil },
      }
    end

    def percentile(sorted, percent)
      return sorted.first.to_f if sorted.size == 1

      rank = (percent / 100.0) * (sorted.size - 1)
      lower = rank.floor
      upper = rank.ceil
      return sorted[lower].to_f if lower == upper

      weight = rank - lower
      (sorted[lower] * (1 - weight)) + (sorted[upper] * weight)
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.nil? || denominator.zero?

      numerator.to_f / denominator
    end
  end
end
