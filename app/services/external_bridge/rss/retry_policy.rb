# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Transient feed failures stay on the subscription and are retried.
    # Authentication and safety failures are terminal until the owner resumes.
    module RetryPolicy
      BASE = 15.minutes
      MAX_DELAY = 6.hours
      JITTER = 60
      CEILING = 5
      TERMINAL = %w(
        authenticated_source_rejected
        private_address
        unsupported_url
      ).freeze

      module_function

      def terminal?(code)
        text = code.to_s
        return true if TERMINAL.include?(text)
        return false if text == 'http_429'

        text.match?(/\Ahttp_4\d\d\z/)
      end

      def delay(retry_count, salt)
        exponent = [[retry_count.to_i - 1, 0].max, 8].min
        base = BASE * (2**exponent)
        capped = base > MAX_DELAY ? MAX_DELAY : base
        capped + (salt.to_i.abs % JITTER)
      end
    end
  end
end
