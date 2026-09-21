# frozen_string_literal: true

# Read-only operator view of the latest Follow Import campaign observed so
# far for one moderation subject.
#
# Composes FollowImportCampaignNegativeTargetOverlapService (#143). It does
# not reimplement grouping or overlap, and it does not attach post-campaign
# outcome labels (#144). Defaults are diagnostic heuristics, not policy.
#
#   * now - lookback <= imported_at <= now. Future batches never enter the
#     campaign union, ended_at, or overlap features.
#   * Latest campaign is picked by ended_at, then started_at, then
#     campaign_index / campaign_key. This is "observed so far", not a claim
#     that the campaign is finished.
#   * Cross-subject linked-negative overlap is behavioral recurrence
#     evidence, not identity proof.
#   * No score, recommendation, gate, enforcement, or writes.
#
# Console / rails runner:
#
#   result = Moderation::FollowImportRecurrenceObservationService.new.call(subject)
#   puts JSON.pretty_generate(result)
module Moderation
  class FollowImportRecurrenceObservationService
    DEFAULT_LOOKBACK = 7.days
    DEFAULT_MAX_GAP = 30.minutes
    REASON_NO_SUBJECT = 'no_moderation_subject'
    REASON_NO_BATCHES = 'no_follow_import_batches_in_lookback'
    REASON_NO_CAMPAIGN = 'no_campaign_row'
    BEST_MATCH_KEYS = FollowImportCampaignNegativeTargetOverlapService::BEST_MATCH_KEYS
    NOTES = [
      'cross-subject linked-negative overlap is behavioral recurrence evidence, not identity proof',
      'fingerprint completeness false means observed overlap is a lower bound',
      'fingerprint completeness nil means unknown, not complete',
      'max_gap is a grouping heuristic, not a policy threshold',
      'absence of recurrence evidence is not proof of safety, especially with partial remote coverage',
    ].freeze

    def initialize(campaign_service: FollowImportCampaignNegativeTargetOverlapService.new)
      @campaign_service = campaign_service
    end

    def call(subject_or_account, now: Time.now.utc, lookback: DEFAULT_LOOKBACK, max_gap: DEFAULT_MAX_GAP)
      lookback_start = now - lookback
      subject = resolve_subject(subject_or_account)
      return observation(no_subject_fields(now, lookback, lookback_start, max_gap)) if subject.nil?

      batches = selected_batches(subject, lookback_start, now)
      batch_count = batches.count
      common = cutoff_fields(subject.id, now, lookback, lookback_start, max_gap).merge(
        'batch_count' => batch_count,
        'campaign_count' => 0
      )
      return observation(common.merge(unavailable(REASON_NO_BATCHES))) if batch_count.zero?

      campaigns = Array(@campaign_service.call(batches, max_gap: max_gap, now: now)['campaigns'])
      latest = pick_latest(campaigns)
      common = common.merge('campaign_count' => campaigns.size)
      return observation(common.merge(unavailable(REASON_NO_CAMPAIGN))) if latest.nil?

      observation(common.merge(available_fields(latest, now)))
    end

    private

    def resolve_subject(subject_or_account)
      return subject_or_account if subject_or_account.is_a?(ModerationSubject)
      return if subject_or_account.nil?

      ModerationSubject.find_by(account_id: subject_or_account.id)
    end

    def selected_batches(subject, lookback_start, now)
      FollowImportBatch
        .where(subject_id: subject.id)
        .where('imported_at >= ?', lookback_start)
        .where('imported_at <= ?', now)
    end

    def pick_latest(campaigns)
      campaigns.max_by do |campaign|
        [
          campaign['ended_at'] || Time.at(0).utc,
          campaign['started_at'] || Time.at(0).utc,
          campaign['campaign_index'].to_i,
          campaign['campaign_key'].to_s,
        ]
      end
    end

    def no_subject_fields(now, lookback, lookback_start, max_gap)
      cutoff_fields(nil, now, lookback, lookback_start, max_gap).merge(
        'batch_count' => 0,
        'campaign_count' => 0
      ).merge(unavailable(REASON_NO_SUBJECT))
    end

    def cutoff_fields(subject_id, now, lookback, lookback_start, max_gap)
      {
        'subject_id'        => subject_id,
        'generated_at'      => now.iso8601,
        'lookback_seconds'  => lookback.to_f,
        'max_gap_seconds'   => max_gap.to_f,
        'imported_at_from'  => lookback_start,
        'imported_at_to'    => now,
      }
    end

    def unavailable(reason)
      {
        'available'        => false,
        'reason'           => reason,
        'latest_campaign'  => nil,
      }
    end

    def available_fields(campaign, now)
      {
        'available'        => true,
        'reason'           => nil,
        'latest_campaign'  => latest_campaign_view(campaign, now),
      }
    end

    def latest_campaign_view(campaign, now)
      ended_at = campaign['ended_at']
      {
        'campaign_key'                       => campaign['campaign_key'],
        'started_at'                         => campaign['started_at'],
        'ended_at'                           => ended_at,
        'duration_seconds'                   => campaign['duration_seconds'],
        'seconds_since_last_batch'           => ended_at && (now - ended_at).to_f,
        'batch_count'                        => campaign['batch_count'],
        'target_rows'                        => campaign['target_rows'],
        'comparable_unique_target_count'     => campaign['comparable_unique_target_count'],
        'unresolved_or_unmapped_target_rows' => campaign['unresolved_or_unmapped_target_rows'],
        'same_subject'                       => category_view(campaign['same_subject']),
        'cross_subject'                      => category_view(campaign['cross_subject']),
      }
    end

    def category_view(block)
      selected = block || {}
      {
        'matching_snapshot_count' => selected['matching_snapshot_count'].to_i,
        'best_match'              => slice_best_match(selected['best_match']),
      }
    end

    def slice_best_match(match)
      return if match.nil?

      BEST_MATCH_KEYS.index_with { |key| match[key] }
    end

    def observation(fields)
      {
        'available'         => fields['available'],
        'reason'            => fields['reason'],
        'subject_id'        => fields['subject_id'],
        'generated_at'      => fields['generated_at'],
        'lookback_seconds'  => fields['lookback_seconds'],
        'max_gap_seconds'   => fields['max_gap_seconds'],
        'imported_at_from'  => fields['imported_at_from'],
        'imported_at_to'    => fields['imported_at_to'],
        'batch_count'       => fields['batch_count'],
        'campaign_count'    => fields['campaign_count'],
        'latest_campaign'   => fields['latest_campaign'],
        'notes'             => NOTES,
      }
    end
  end
end
