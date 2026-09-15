# frozen_string_literal: true

# Time parsing and duration helpers for Follow Import telemetry.
# A missing timestamp yields NULL duration — never a synthetic 0.
module FollowImport
  module ObservationTime
    module_function

    def parse(value)
      return if value.blank?
      return value.utc if value.respond_to?(:utc) && (value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone))

      Time.iso8601(value.to_s).utc
    rescue StandardError
      Time.zone.parse(value.to_s)&.utc
    rescue StandardError
      nil
    end

    def duration_ms(started_at, finished_at)
      return if started_at.blank? || finished_at.blank?

      ms = ((finished_at - started_at) * 1000).round
      # A backwards interval is unusable, not an observed zero.
      ms.negative? ? nil : ms
    end
  end
end
