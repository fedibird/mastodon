# frozen_string_literal: true

module FollowImport
  class PacingBacktest
    Attempt = Struct.new(
      :row_number,
      :phase,
      :target_id,
      :destination_domain,
      :endpoint_origin,
      :started_at,
      :finished_at,
      :request_started_at,
      :request_finished_at,
      :enqueued_at,
      :queue_wait_ms,
      :request_duration_ms,
      :outcome,
      :http_status,
      :retry_after_seconds,
      :error_class,
      :event_time,
      :attempt_ordinal,
      :malformed_fields,
      keyword_init: true
    ) do
      def delivery?
        phase.to_s == 'activitypub_delivery'
      end

      def timed?
        !event_time.nil?
      end

      def first_attempt?
        attempt_ordinal == 1
      end

      def retry_attempt?
        attempt_ordinal.to_i >= 2
      end

      def success?
        return outcome.to_s == 'http_success' if outcome.present?
        return false if http_status.nil?

        (200...300).cover?(http_status)
      end

      def failed?
        !success?
      end
    end
  end
end
