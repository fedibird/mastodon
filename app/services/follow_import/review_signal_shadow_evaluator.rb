# frozen_string_literal: true

# Builds one privacy-minimized shadow observation for a Follow Import batch.
#
# Feature cutoff is batch.imported_at, not the wall clock. Later batches and
# later moderation actions stay outside the recurrence observation. evaluated_at
# records when this process ran. A raised error is not turned into a signal;
# the worker retries instead of storing a fabricated result.
module FollowImport
  class ReviewSignalShadowEvaluator
    SCHEMA_VERSION = 1
    REASON_UNAVAILABLE = 'recurrence_observation_unavailable'

    def initialize(observation_service: Moderation::FollowImportRecurrenceObservationService.new,
                   classifier: FollowImport::ReviewSignalClassifier.new,
                   clock: -> { Time.now.utc })
      @observation_service = observation_service
      @classifier = classifier
      @clock = clock
    end

    def call(batch)
      observation = @observation_service.call(
        batch.subject,
        now: batch.imported_at,
        lookback: Moderation::FollowImportRecurrenceObservationService::DEFAULT_LOOKBACK,
        max_gap: Moderation::FollowImportRecurrenceObservationService::DEFAULT_MAX_GAP
      )
      return unavailable_payload(batch) unless observation.is_a?(Hash) && observation['available'] == true && observation['latest_campaign'].is_a?(Hash)

      campaign = observation['latest_campaign']
      classified = @classifier.call(classifier_input(batch, campaign))
      envelope(batch, classified['signal_level'], classified['reason_codes'], classified['features'])
    end

    private

    def classifier_input(batch, campaign)
      cross = campaign['cross_subject'].is_a?(Hash) ? campaign['cross_subject'] : {}
      same = campaign['same_subject'].is_a?(Hash) ? campaign['same_subject'] : {}
      {
        'cross_subject_best_match' => cross['best_match'],
        'campaign_batch_count' => campaign['batch_count'],
        'target_rows' => campaign['target_rows'],
        'comparable_unique_target_count' => campaign['comparable_unique_target_count'],
        'unresolved_or_unmapped_target_rows' => campaign['unresolved_or_unmapped_target_rows'],
        'cross_subject_matching_snapshot_count' => cross['matching_snapshot_count'],
        'same_subject_matching_snapshot_count' => same['matching_snapshot_count'],
        'mode' => batch.mode,
        'migration_evidence' => batch.migration_evidence,
        'account_age_seconds' => batch.account_age_seconds,
        'dispatch_owner' => batch.dispatch_owner,
      }
    end

    def unavailable_payload(batch)
      classified = @classifier.call(classifier_input(batch, {}))
      envelope(batch, 'none', [REASON_UNAVAILABLE], classified['features'])
    end

    def envelope(batch, signal_level, reason_codes, features)
      {
        'schema_version' => SCHEMA_VERSION,
        'classifier_version' => FollowImport::ReviewSignalClassifier::VERSION,
        'evaluation_status' => 'ok',
        'evaluated_at' => @clock.call.utc.iso8601,
        'as_of' => batch.imported_at.utc.iso8601,
        'signal_level' => signal_level,
        'reason_codes' => reason_codes,
        'features' => features,
      }
    end
  end
end
