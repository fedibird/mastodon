# frozen_string_literal: true

# Failure-tolerant writers for Follow Import transport/load telemetry.
# Insert or snapshot failures are logged (rate-limited) and never raised to
# the Follow Import business path. Nil count/duration values stay nil — they
# are not coerced to 0.
module FollowImport
  class Telemetry
    SCHEMA_VERSION = 2
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
          duration_ms: FollowImport::ObservationTime.duration_ms(started_at, finished_at) || 0,
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
