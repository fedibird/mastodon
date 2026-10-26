# frozen_string_literal: true

module Mastodon
  class Error < StandardError; end
  class NotPermittedError < Error; end
  class ValidationError < Error; end
  class HostValidationError < ValidationError; end
  class LengthValidationError < ValidationError; end
  class DimensionsValidationError < ValidationError; end
  class StreamValidationError < ValidationError; end
  class RejectPayload < ValidationError; end
  class RaceConditionError < Error; end
  class RateLimitExceededError < Error; end
  class InvalidParameterError < Error; end

  # Structured emoji-reaction fallback response. `error` stays a stable
  # sentence. `error_code` and `details` are additive. Details never include
  # the account, the status id, or the node document; the confirmation token
  # is the only secret, and it is the value the client must send back.
  class EmojiReactionPolicyError < Error
    FORBIDDEN = 'This action is not allowed'
    CONFIRM_REQUIRED = 'Confirmation is required before this reaction is sent as a favourite to the server of the post'
    # Used when the legacy sender still enqueues EmojiReact but the capability
    # is unknown. It must not say the reaction is sent as a favourite.
    CONFIRM_REQUIRED_UNKNOWN = 'Confirmation is required before this reaction is sent. Emoji-reaction support on the server of the post is not known, and this reaction is sent as an emoji reaction.'
    CONFIRM_INVALID = 'Confirmation is no longer valid'
    UNAVAILABLE = 'There was a temporary problem serving your request, please try again'

    attr_reader :http_status, :error_code, :details

    def initialize(http_status:, error_code:, message:, details: nil)
      @http_status = http_status
      @error_code = error_code
      @details = details
      super(message)
    end

    def self.fallback_denied
      new(http_status: 403, error_code: 'fallback_denied', message: FORBIDDEN, details: { 'mechanism' => 'like_fallback' })
    end

    def self.unknown_denied
      new(http_status: 403, error_code: 'capability_unknown_denied', message: FORBIDDEN)
    end

    def self.confirmation_required(details, message: CONFIRM_REQUIRED)
      new(http_status: 409, error_code: 'fallback_confirmation_required', message: message, details: details)
    end

    def self.confirmation_invalid(details)
      new(http_status: 409, error_code: 'fallback_confirmation_invalid', message: CONFIRM_INVALID, details: details)
    end

    def self.confirmation_unavailable
      new(http_status: 503, error_code: 'fallback_confirmation_unavailable', message: UNAVAILABLE)
    end
  end

  class UnexpectedResponseError < Error
    attr_reader :response

    def initialize(response = nil)
      @response = response

      if response.respond_to? :uri
        super("#{response.uri} returned code #{response.code}")
      else
        super
      end
    end
  end

  class PrivateNetworkAddressError < HostValidationError
    attr_reader :host

    def initialize(host)
      @host = host
      super()
    end
  end
end
