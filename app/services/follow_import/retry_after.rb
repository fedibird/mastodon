# frozen_string_literal: true

# Best-effort parse of an HTTP Retry-After value. Accepts delta-seconds or an
# HTTP-date. Returns nil when the header is missing or not safely parseable.
module FollowImport
  module RetryAfter
    module_function

    def seconds_from(response)
      raw = header_value(response)
      return if raw.blank?

      return raw.to_i if raw.match?(/\A\d+\z/)

      time = Time.httpdate(raw)
      seconds = (time - Time.now).to_i
      seconds.negative? ? 0 : seconds
    rescue StandardError
      nil
    end

    def header_value(response)
      return if response.nil? || !response.respond_to?(:headers)

      headers = response.headers
      value = headers['Retry-After'] || headers['retry-after']
      value = value.first if value.is_a?(Array)
      value.to_s.strip.presence
    rescue StandardError
      nil
    end
  end
end
