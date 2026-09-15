# frozen_string_literal: true

# Read-only aggregation of raw vs qualified vs unqualified ledger negatives.
#
# Qualification is delegated entirely to NegativeSignalQualification (which
# reuses PrecedingContactLink). This query does not score, write, or invent
# per-type rules. Event types that are not modeled as ledger rejections are
# omitted from +by_type+ rather than forced into the same buckets.
module Moderation
  class NegativeSignalQuery
    REJECTION_TYPES = BehavioralMetricsService::REJECTION_TYPES

    def initialize(qualification: NegativeSignalQualification)
      @qualification = qualification
    end

    def summarize(subject, window_start:, window_end:)
      return empty_summary if subject.nil?

      events = ModerationRejectionEvent
               .where(rejected_subject_id: subject.id)
               .where(occurred_at: window_start..window_end)
               .includes(:preceding_interaction_event)
               .to_a

      summarize_events(events)
    end

    def summarize_events(events)
      by_type = empty_by_type
      qualified_count = 0
      unqualified_count = 0

      events.each do |event|
        qualified = @qualification.qualified?(event)
        if qualified
          qualified_count += 1
        else
          unqualified_count += 1
        end

        bucket = by_type[event.event_type.to_s]
        next if bucket.nil?

        bucket['raw'] += 1
        if qualified
          bucket['qualified'] += 1
        else
          bucket['unqualified'] += 1
        end
      end

      {
        'raw_events' => events.size,
        'qualified_events' => qualified_count,
        'unqualified_events' => unqualified_count,
        'by_type' => by_type,
      }
    end

    def empty_summary
      {
        'raw_events' => 0,
        'qualified_events' => 0,
        'unqualified_events' => 0,
        'by_type' => empty_by_type,
      }
    end

    private

    def empty_by_type
      REJECTION_TYPES.index_with { { 'raw' => 0, 'qualified' => 0, 'unqualified' => 0 } }
    end
  end
end
