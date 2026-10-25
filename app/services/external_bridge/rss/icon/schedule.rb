# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Icon
      # When a shared source icon is looked at again. One decision for the
      # whole source, never per subscriber and never per article.
      #
      # icon_next_check_at is the only gate. A stored icon is re-validated with
      # its validators once a week. A source with no icon, or whose last check
      # failed, waits out an increasing backoff, so a feed with no usable image
      # costs a handful of requests a month and not one per poll.
      module Schedule
        RECHECK_INTERVAL = 7.days
        BACKOFF = [1.hour, 6.hours, 24.hours, 3.days, 7.days].freeze

        module_function

        def due?(source, now = Time.current)
          source.icon_next_check_at.nil? || source.icon_next_check_at <= now
        end

        def success_at(now = Time.current)
          now + RECHECK_INTERVAL
        end

        def failure_at(failure_count, now = Time.current)
          step = BACKOFF[[failure_count.to_i - 1, 0].max] || BACKOFF.last
          now + step
        end

        # Called after a feed fetch succeeded. A declined or failed push is
        # never an error for the caller: the scheduler picks the source up.
        def enqueue_if_due(source)
          return false if source.nil? || !Feature.enabled? || !due?(source)

          ExternalBridge::RSS::IconRefreshWorker.perform_async(source.id).present?
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] icon enqueue skipped source=#{source&.id} code=#{e.class}")
          false
        end
      end
    end
  end
end
