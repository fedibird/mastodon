# frozen_string_literal: true

# Internal delivery envelope for FeedInsertWorker.
#
# A reason is evidence that fan-out selected a destination. It is not permission
# to show the status. Block, mute, domain block, language, list, and account
# checks still run. Only the keyword re-match can be skipped, and only when the
# evidence is still the same subscription and the same status edit.
#
# FEED_DELIVERY_REASON_MODE:
#   off     - default. Job shape and checks stay as they are. Evidence is ignored.
#   shadow  - keyword jobs carry evidence. Decisions stay on the old checks,
#             and aggregate counters compare the two.
#   enforce - a fresh keyword evidence skips KeywordSubscribe.match?. Stale,
#             missing, or unknown evidence falls back to the old check.
#
# Unknown and reserved reasons are never treated as an allow. Production stays
# on off until the shadow counters have been read. This does not by itself
# remove the first scan over every subscription.
module FeedDelivery
  MODE_ENV = 'FEED_DELIVERY_REASON_MODE'
  MODES = %i(off shadow enforce).freeze

  # Names later routes can use without a new envelope version. Only keyword
  # is produced and accepted until that route is implemented.
  KNOWN_REASONS = %w(keyword follow tag domain account mention list).freeze
  ACTIVE_REASONS = %w(keyword).freeze

  module_function

  def mode
    value = ENV.fetch(MODE_ENV, 'off').to_s.strip.downcase.to_sym
    MODES.include?(value) ? value : :off
  end

  def observe?
    mode != :off
  end

  def shadow?
    mode == :shadow
  end

  def enforce?
    mode == :enforce
  end

  def usec(time)
    return nil if time.blank?

    (time.to_r * 1_000_000).to_i
  end

  def normalize_list_id(list_id)
    return nil if list_id.nil?
    return list_id if list_id.is_a?(Integer)

    list_id.respond_to?(:id) ? list_id.id : list_id
  end

  # Attaches evidence only when it names this receiver. A copied payload for
  # another account or list is dropped and cannot satisfy the keyword clause.
  def attach!(crutches, delivery, account_id:, list_id:)
    return crutches unless observe?
    return crutches unless delivery.is_a?(Evidence)
    return crutches unless delivery.bound_to?(account_id: account_id, list_id: list_id)

    crutches[:delivery_evidence] = delivery
    crutches
  end

  def issue_decision(attrs)
    previous = Thread.current[:feed_delivery_issuing]
    Thread.current[:feed_delivery_issuing] = true
    InsertDecision.construct(attrs)
  ensure
    Thread.current[:feed_delivery_issuing] = previous
  end

  def issuing_decision?
    Thread.current[:feed_delivery_issuing] == true
  end
end
