# frozen_string_literal: true

# Observes one ActivityPub::DeliveryWorker execution for a Follow Import
# target. Classifies from the actual HTTP status / exception — never from
# DeliveryWorker's @performed flag, which is also set for unsalvageable
# responses. Recording failures never raise.
module FollowImport
  class DeliveryObserver
    def self.record_attempt(options:, inbox_url:, sidekiq_queue:, sidekiq_job_id:, started_at:, response:, error:, skip_reason:, performed:)
      return unless follow_import_target?(options)

      tracking = tracking_from(options)
      target_id = tracking[:id]
      target = FollowImportTarget.find_by(id: target_id)
      http_response = response || response_from(error)

      FollowImport::Telemetry.record_transport(
        batch_id: target&.batch_id,
        target_id: target_id,
        phase: 'activitypub_delivery',
        destination_domain: target&.destination_domain,
        endpoint_origin: FollowImport::EndpointOrigin.from_url(inbox_url),
        sidekiq_queue: sidekiq_queue,
        sidekiq_job_id: sidekiq_job_id,
        started_at: started_at,
        finished_at: Time.now.utc,
        outcome: delivery_outcome(http_response, error, skip_reason),
        http_status: http_status_from(http_response),
        retry_after_seconds: FollowImport::RetryAfter.seconds_from(http_response),
        error_class: error&.class&.name,
        metadata: {
          'schema' => FollowImport::Telemetry::SCHEMA_NAME,
          'schema_version' => FollowImport::Telemetry::SCHEMA_VERSION,
          'performed' => performed,
          'skip_reason' => skip_reason,
        }.compact
      )
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('transport', e)
      nil
    end

    def self.follow_import_target?(options)
      tracking = tracking_from(options)
      tracking[:type].to_s == 'follow_import_target' && tracking[:id].present?
    end

    def self.tracking_from(options)
      return {} if options.blank?

      raw = options.with_indifferent_access[:delivery_tracking]
      raw.respond_to?(:to_h) ? raw.to_h.with_indifferent_access : {}
    rescue StandardError
      {}
    end
    private_class_method :tracking_from

    def self.response_from(error)
      error.respond_to?(:response) ? error.response : nil
    end
    private_class_method :response_from

    def self.http_status_from(response)
      return unless response.respond_to?(:code)

      Integer(response.code)
    rescue StandardError
      nil
    end
    private_class_method :http_status_from

    def self.delivery_outcome(response, error, skip_reason)
      return skip_reason if skip_reason.present?
      return classify_exception(error) if error
      return classify_response(response) if response

      'unknown'
    end
    private_class_method :delivery_outcome

    def self.classify_exception(error)
      case error
      when Mastodon::UnexpectedResponseError
        'http_retryable'
      when HTTP::TimeoutError
        'timeout'
      when HTTP::ConnectionError, OpenSSL::SSL::SSLError
        'connection_failure'
      when Stoplight::Error::RedLight
        'circuit_or_stoplight_interruption'
      else
        'unknown_exception'
      end
    end
    private_class_method :classify_exception

    def self.classify_response(response)
      status = http_status_from(response)
      return 'unknown' if status.nil?
      return 'http_success' if (200...300).cover?(status)

      'http_unsalvageable'
    end
    private_class_method :classify_response
  end
end
