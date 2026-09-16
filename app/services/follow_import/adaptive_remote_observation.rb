# frozen_string_literal: true

# Pure transport-event classifier for adaptive remote pacing.
#
# Inputs are actual ActivityPub delivery observations only:
# HTTP status, transport exception, and whether a request started.
# HTTP status wins when both status and exception are present, so a
# 503 wrapped in Mastodon::UnexpectedResponseError is a 5xx failure.
#
# Not consulted:
#   Accept / Reject / follow business states
#   Follow Gate / blocks / mutes / reports / moderation
#   request_duration / latency
#   Node capacity / remote software / user counts
#   importing account identity / owner_key / CSV size
#
# Stoplight-open or DFT skip before a request starts is NEUTRAL so
# the controller does not stack a second decrease on a request that
# never left the local process.
module FollowImport
  class AdaptiveRemoteObservation
    SUCCESS    = 'success'
    RATE_LIMIT = 'rate_limit'
    FAILURE    = 'failure'
    NEUTRAL    = 'neutral'

    Result = Struct.new(:event, :http_status, :request_reached, keyword_init: true)

    def self.classify(http_status: nil, error: nil, request_started_at: nil)
      request_reached = request_started_at.present?
      status = coerce_status(http_status) || status_from(error)

      unless request_reached
        return Result.new(event: NEUTRAL, http_status: status, request_reached: false)
      end

      event = if status
                classify_status(status)
              else
                classify_error(error)
              end

      Result.new(event: event, http_status: status, request_reached: true)
    end

    def self.mutating?(event)
      event == SUCCESS || event == RATE_LIMIT || event == FAILURE
    end

    def self.coerce_status(value)
      return if value.nil?

      Integer(value)
    rescue StandardError
      nil
    end
    private_class_method :coerce_status

    def self.status_from(error)
      return unless error.respond_to?(:response)

      response = error.response
      return unless response.respond_to?(:code)

      Integer(response.code)
    rescue StandardError
      nil
    end
    private_class_method :status_from

    def self.classify_status(status)
      return SUCCESS if (200...300).cover?(status)
      return RATE_LIMIT if status == 429
      return FAILURE if (500...600).cover?(status)
      return NEUTRAL if (300...500).cover?(status)

      NEUTRAL
    end
    private_class_method :classify_status

    def self.classify_error(error)
      case error
      when HTTP::TimeoutError
        FAILURE
      when HTTP::ConnectionError, OpenSSL::SSL::SSLError
        FAILURE
      else
        NEUTRAL
      end
    end
    private_class_method :classify_error
  end
end
