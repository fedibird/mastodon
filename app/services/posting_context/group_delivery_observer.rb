# frozen_string_literal: true

# Classifies one ActivityPub::DeliveryWorker execution for a group inbox
# observation. HTTP 2xx comes only from the response code. @performed is
# also set for unsalvageable responses, so it is not a success signal.
#
# Recording never raises. Follow-import delivery_tracking is not read
# or written here.
class PostingContext::GroupDeliveryObserver
  class << self
    def record_attempt(options:, response:, error:, skip_reason:, request_started_at:)
      key = observation_key(options)
      return if key.nil?

      PostingContext::GroupFederationObservation.apply_attempt(
        key,
        attempt_event(response: response, error: error, skip_reason: skip_reason, request_started_at: request_started_at)
      )
    rescue StandardError => e
      Rails.logger.warn("[PostingContext::GroupDeliveryObserver] #{e.class}")
      nil
    end

    def record_terminal(options)
      key = observation_key(options)
      return if key.nil?

      PostingContext::GroupFederationObservation.mark_terminal(key)
    rescue StandardError => e
      Rails.logger.warn("[PostingContext::GroupDeliveryObserver] #{e.class}")
      nil
    end

    private

    def observation_key(options)
      return if options.blank?

      key = options.with_indifferent_access[PostingContext::GroupFederationObservation::OPTION]
      key if PostingContext::GroupFederationObservation.valid_key?(key)
    rescue StandardError
      nil
    end

    def attempt_event(response:, error:, skip_reason:, request_started_at:)
      classified = classify(response: response, error: error, skip_reason: skip_reason)
      {
        'outcome' => classified[:outcome],
        'http_status' => classified[:http_status],
        'http_attempt' => classified[:http_attempt],
        'http_2xx' => classified[:http_2xx],
        'request_started_at' => timestamp(request_started_at),
        'observed_at' => Time.now.utc.iso8601,
      }
    end

    def classify(response:, error:, skip_reason:)
      return non_http('availability_suppression') if skip_reason == 'availability_suppression'
      return non_http('circuit_interruption') if stoplight_error?(error)

      status = http_status_from(response) || http_status_from(response_from(error))
      return http_result('timeout', status) if timeout_error?(error)
      return http_result('connection_failure', status) if connection_error?(error)
      return http_result('http_success', status, http_2xx: true) if status && (200...300).cover?(status)
      return http_result('http_retryable', status) if error.is_a?(Mastodon::UnexpectedResponseError)
      return http_result('http_unsalvageable', status) if status

      non_http('not_attempted')
    end

    def non_http(outcome)
      { outcome: outcome, http_status: nil, http_attempt: false, http_2xx: false }
    end

    def http_result(outcome, status, http_2xx: false)
      { outcome: outcome, http_status: status, http_attempt: true, http_2xx: http_2xx }
    end

    def response_from(error)
      error.respond_to?(:response) ? error.response : nil
    end

    def http_status_from(response)
      return unless response.respond_to?(:code)

      Integer(response.code)
    rescue ArgumentError, TypeError
      nil
    end

    def timeout_error?(error)
      defined?(HTTP::TimeoutError) && error.is_a?(HTTP::TimeoutError)
    end

    def connection_error?(error)
      (defined?(HTTP::ConnectionError) && error.is_a?(HTTP::ConnectionError)) || error.is_a?(OpenSSL::SSL::SSLError)
    end

    def stoplight_error?(error)
      defined?(Stoplight::Error::RedLight) && error.is_a?(Stoplight::Error::RedLight)
    end

    def timestamp(time)
      return '' if time.blank?

      time.utc.iso8601(6)
    rescue StandardError
      ''
    end
  end
end
