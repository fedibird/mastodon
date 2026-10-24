# frozen_string_literal: true

module ExternalBridge
  module RSS
    # One-line, key=value INFO records for the RSS scheduler and source refresh.
    #
    # Only identifiers, fixed outcome and error codes, and small counters are
    # written. A value that is not a short token is replaced with "-", so a URL,
    # header, title, GUID, user detail, or exception message cannot reach the log
    # even if a caller passes one by mistake. A logging failure never reaches the
    # caller.
    module RefreshLog
      PREFIX = '[ExternalBridge::RSS]'
      SAFE_VALUE = /\A[A-Za-z0-9_.,:-]{1,200}\z/

      module_function

      def emit(event, fields)
        Rails.logger.info(line(event, fields))
        nil
      rescue StandardError
        nil
      end

      def line(event, fields)
        pairs = fields.filter_map do |key, value|
          next if value.nil?

          "#{key}=#{safe(value)}"
        end
        "#{PREFIX} event=#{event} #{pairs.join(' ')}".strip
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_ms(started)
        ((now - started) * 1000).round
      end

      # Error codes are fixed identifiers in this codebase; anything else is
      # reported as "unknown" rather than echoed.
      def code(value)
        text = value.to_s
        text.match?(/\A[a-z0-9_]{1,48}\z/) ? text : 'unknown'
      end

      def safe(value)
        text = value.is_a?(Array) ? value.join(',') : value.to_s
        text.match?(SAFE_VALUE) ? text : '-'
      end
    end
  end
end
