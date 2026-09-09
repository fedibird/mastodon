# frozen_string_literal: true

# Configurable retention policy for the moderation ledger. The retention period
# is intentionally not hardcoded: it is read from the environment so operators
# can tune it after privacy/legal review.
#
# Operational semantics of MODERATION_LEDGER_RETENTION_DAYS / +retention_until+:
#
#   * The value is the *earliest eligibility* for deleting a tombstoned
#     subject — not a hard deletion deadline. Rows are not guaranteed gone
#     on day N.
#   * After +retention_until+, the scheduler still holds that subject (and
#     any shared events) while a retained counterpart needs the evidence.
#     One participant's expiry must not erase another subject's history.
#   * A non-positive value disables expiry (records are kept indefinitely).
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

    # Earliest time a subject tombstoned at +from+ becomes eligible for
    # deletion, or nil when retention is disabled (kept indefinitely).
    # Eligibility is not a hard deadline: shared evidence may hold the
    # subject longer. See the module comment.
    def expire_at(from = Time.now.utc)
      return nil unless enabled?

      from + duration
    end
  end
end
