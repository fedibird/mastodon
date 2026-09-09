# frozen_string_literal: true

# Configurable retention policy for the moderation ledger. The retention period
# is intentionally not hardcoded: it is read from the environment so operators
# can tune it after privacy/legal review.
#
# A tombstoned subject (its account was deleted/purged) is kept until
# +retention_until+, after which the retention cleanup scheduler removes it and,
# via foreign keys, its recorded events. A non-positive value disables
# expiry (records are kept indefinitely).
module Moderation
  module RetentionPolicy
    DEFAULT_RETENTION_DAYS = 365

    module_function

    def retention_days
      value = ENV.fetch('MODERATION_LEDGER_RETENTION_DAYS', DEFAULT_RETENTION_DAYS).to_i
      value.negative? ? 0 : value
    rescue ArgumentError, TypeError
      DEFAULT_RETENTION_DAYS
    end

    def enabled?
      retention_days.positive?
    end

    def duration
      retention_days.days
    end

    # When a subject tombstoned at +from+ should expire, or nil when retention
    # is disabled (kept indefinitely).
    def expire_at(from = Time.now.utc)
      return nil unless enabled?

      from + duration
    end
  end
end
