# frozen_string_literal: true

# Shared read-only test for a *qualified* negative signal.
#
# A ledger rejection is qualified only when it has a strong preceding-contact
# association (Moderation::PrecedingContactLink). This is the same rule
# BehavioralMetricsService uses for first_negative_signal_at / continuation.
# Unlinked or synthetic Follow Rejects remain raw observations and must not
# become a continuation or repeat_behavior anchor.
#
# This module does not invent a new qualification rule.
module Moderation
  module NegativeSignalQualification
    module_function

    def qualified?(event)
      return false if event.nil?

      PrecedingContactLink.strong_association?(event.preceding_interaction_event, event)
    end

    def first_qualified_at(events)
      earliest = nil

      events.each do |event|
        next unless qualified?(event)

        at = event.occurred_at
        next if at.nil?

        earliest = at if earliest.nil? || at < earliest
      end

      earliest
    end
  end
end
