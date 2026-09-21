# frozen_string_literal: true

# Failure-tolerant writers for Follow Import transport/load telemetry.
# Insert or snapshot failures are logged (rate-limited) and never raised to
# the Follow Import business path. Nil count/duration values stay nil — they
# are not coerced to 0.
module FollowImport
  class Telemetry
    SCHEMA_VERSION = 4
    # Tick observation contract is versioned separately
    # (DispatchTickObserver::SCHEMA_VERSION). Transport/dispatch-pass
    # rows keep this schema.
    SCHEMA_NAME    = 'follow_import_pacing_telemetry'
    WARN_TTL       = 60

    class << self
      include Redisable

      def record_transport(**attrs)
        FollowImportTransportObservation.create!(transport_attributes(attrs))
      rescue StandardError => e
        warn_failure('transport', e)
        nil
      end

      def record_dispatch(**attrs)
        FollowImportDispatchObservation.create!(dispatch_attributes(attrs))
      rescue StandardError => e
        warn_failure('dispatch', e)
        nil
      end

      def record_dispatch_tick(**attrs)
        FollowImportDispatchTickObservation.create!(dispatch_tick_attributes(attrs))
      rescue StandardError => e
        warn_failure('dispatch_tick', e)
        nil
      end

      def warn_failure(kind, error)
        return unless allow_warning?(kind, error.class.name)

        Rails.logger.warn("[FollowImport::Telemetry] failed to record #{kind} observation: #{error.class}: #{error.message}")
      rescue StandardError
        nil
      end

      private

      def transport_attributes(attrs)
        started_at  = attrs[:started_at]
        finished_at = attrs[:finished_at] || Time.now.utc
        {
          batch_id: attrs[:batch_id],
          target_id: attrs[:target_id],
          phase: attrs[:phase],
          destination_domain: attrs[:destination_domain],
          endpoint_origin: attrs[:endpoint_origin],
          sidekiq_queue: attrs[:sidekiq_queue],
          sidekiq_job_id: attrs[:sidekiq_job_id],
          started_at: started_at,
          finished_at: finished_at,
          duration_ms: FollowImport::ObservationTime.duration_ms(started_at, finished_at),
          enqueued_at: attrs[:enqueued_at],
          request_started_at: attrs[:request_started_at],
          request_finished_at: attrs[:request_finished_at],
          queue_wait_ms: attrs[:queue_wait_ms],
          request_duration_ms: attrs[:request_duration_ms],
          outcome: attrs[:outcome],
          http_status: attrs[:http_status],
          retry_after_seconds: attrs[:retry_after_seconds],
          error_class: attrs[:error_class],
          metadata: attrs[:metadata].presence || {},
          created_at: Time.now.utc,
        }
      end

      def dispatch_tick_attributes(attrs) # rubocop:disable Metrics/MethodLength
        mode = attrs[:scheduler_mode].to_s
        mode = 'shadow' if mode.blank?

        {
          observed_at: attrs[:observed_at] || Time.now.utc,
          tick_id: attrs[:tick_id],
          scheduler_mode: mode,
          lease_acquired: attrs[:lease_acquired],
          outcome: attrs[:outcome],
          global_pending_count: attrs[:global_pending_count],
          active_batch_count: attrs[:active_batch_count],
          historical_pending_count: attrs[:historical_pending_count],
          operational_pending_count: attrs[:operational_pending_count],
          planning_pending_count: attrs[:planning_pending_count],
          historical_active_batch_count: attrs[:historical_active_batch_count],
          operational_active_batch_count: attrs[:operational_active_batch_count],
          planning_active_batch_count: attrs[:planning_active_batch_count],
          # Shadow mode never claims. Force 0 even if a buggy caller
          # supplies another value. Global mode persists the actual
          # successfully-enqueued count (0 is a real observation).
          claimed_count: tick_claimed_count(mode, attrs[:claimed_count]),
          planned_count: attrs[:planned_count],
          planned_owner_count: attrs[:planned_owner_count],
          planned_batch_count: attrs[:planned_batch_count],
          executable_owner_count: attrs[:executable_owner_count],
          executable_batch_count: attrs[:executable_batch_count],
          unique_destination_count: attrs[:unique_destination_count],
          skipped_missing_owner_count: attrs[:skipped_missing_owner_count],
          fairness_state_source: attrs[:fairness_state_source],
          local_load_state: attrs[:local_load_state],
          local_load_budget_percent: attrs[:local_load_budget_percent],
          local_load_recommended_budget: attrs[:local_load_recommended_budget],
          effective_shadow_plan_budget: attrs[:effective_shadow_plan_budget],
          local_load_would_skip: attrs[:local_load_would_skip],
          local_load_measurement_complete: attrs[:local_load_measurement_complete],
          local_load_profile_version: attrs[:local_load_profile_version],
          local_load_profile_source: attrs[:local_load_profile_source],
          local_load_fallback_used: attrs[:local_load_fallback_used],
          global_base_budget: attrs[:global_base_budget],
          effective_global_budget: attrs[:effective_global_budget],
          skipped_stale_count: attrs[:skipped_stale_count],
          skipped_unrecoverable_count: attrs[:skipped_unrecoverable_count],
          skipped_wrong_owner_count: attrs[:skipped_wrong_owner_count],
          remote_admission_enabled: attrs[:remote_admission_enabled],
          remote_admission_configured: attrs[:remote_admission_configured],
          remote_profile_version: attrs[:remote_profile_version],
          skipped_destination_cap_count: attrs[:skipped_destination_cap_count],
          skipped_origin_cap_count: attrs[:skipped_origin_cap_count],
          skipped_unavailable_count: attrs[:skipped_unavailable_count],
          skipped_retry_after_count: attrs[:skipped_retry_after_count],
          skipped_recent_429_count: attrs[:skipped_recent_429_count],
          scanned_target_count: attrs[:scanned_target_count],
          windows_scanned: attrs[:windows_scanned],
          scan_budget_exhausted_count: attrs[:scan_budget_exhausted_count],
          mapped_origin_candidate_count: attrs[:mapped_origin_candidate_count],
          adaptive_remote_shadow_enabled: attrs[:adaptive_remote_shadow_enabled],
          adaptive_remote_configured: attrs[:adaptive_remote_configured],
          adaptive_profile_version: attrs[:adaptive_profile_version],
          adaptive_shadow_evaluated_current_claim_count: attrs[:adaptive_shadow_evaluated_current_claim_count],
          adaptive_shadow_would_block_current_claim_count: attrs[:adaptive_shadow_would_block_current_claim_count],
          adaptive_shadow_destination_would_block_count: attrs[:adaptive_shadow_destination_would_block_count],
          adaptive_shadow_origin_would_block_count: attrs[:adaptive_shadow_origin_would_block_count],
          adaptive_runtime_unavailable_count: attrs[:adaptive_runtime_unavailable_count],
          adaptive_destination_cap_min: attrs[:adaptive_destination_cap_min],
          adaptive_destination_cap_max: attrs[:adaptive_destination_cap_max],
          adaptive_origin_cap_min: attrs[:adaptive_origin_cap_min],
          adaptive_origin_cap_max: attrs[:adaptive_origin_cap_max],
          load_snapshot: attrs[:load_snapshot],
          execution_config: attrs[:execution_config],
          error_class: attrs[:error_class],
          metadata: attrs[:metadata].presence || {},
          created_at: Time.now.utc,
        }
      end

      def tick_claimed_count(mode, value)
        return 0 if mode == 'shadow'

        value.nil? ? 0 : value.to_i
      end

      def dispatch_attributes(attrs)
        {
          batch_id: attrs[:batch_id],
          observed_at: attrs[:observed_at] || Time.now.utc,
          candidate_count: attrs[:candidate_count],
          claimed_count: attrs[:claimed_count],
          pending_count: attrs[:pending_count],
          batch_pending_before: attrs[:batch_pending_before],
          batch_pending_after: attrs[:batch_pending_after],
          global_pending_count: attrs[:global_pending_count],
          active_batch_count: attrs[:active_batch_count],
          load_snapshot: attrs[:load_snapshot],
          execution_policy: attrs[:execution_policy].presence || {},
          pass_error_class: attrs[:pass_error_class],
          local_load_enforcement_enabled: attrs[:local_load_enforcement_enabled],
          local_load_state: attrs[:local_load_state],
          local_load_budget_percent: attrs[:local_load_budget_percent],
          local_load_recommended_budget: attrs[:local_load_recommended_budget],
          effective_execution_budget: attrs[:effective_execution_budget],
          local_load_would_skip: attrs[:local_load_would_skip],
          local_load_measurement_complete: attrs[:local_load_measurement_complete],
          local_load_profile_version: attrs[:local_load_profile_version],
          local_load_profile_source: attrs[:local_load_profile_source],
          local_load_fallback_used: attrs[:local_load_fallback_used],
          load_deferred: attrs[:load_deferred],
          local_load_decision: attrs[:local_load_decision],
          created_at: Time.now.utc,
        }
      end

      def allow_warning?(kind, error_class)
        key = "follow_import:telemetry_warn:#{kind}:#{error_class}"
        redis.set(key, '1', nx: true, ex: WARN_TTL)
      rescue StandardError
        true
      end
    end
  end
end
