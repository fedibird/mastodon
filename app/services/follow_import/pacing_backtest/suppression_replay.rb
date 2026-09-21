# frozen_string_literal: true

# Replay observed HTTP attempts through hypothetical Retry-After /
# recent-429 suppression windows. Matches RemoteRuntimeState honour
# rules without writing Redis.
module FollowImport
  class PacingBacktest
    class SuppressionReplay
      State = Struct.new(:honor_until, :reason, keyword_init: true)

      def initialize(rows, profile)
        @rows = rows
        @profile = profile
      end

      def to_h
        states = {}
        in_retry_after = 0
        in_recent_cooldown = 0
        firsts = 0
        retries = 0
        targets = {}

        timed = @rows.select { |row| row.timed? && row.endpoint_origin.present? }
        timed.sort_by { |row| [row.event_time.to_f, row.row_number] }.each do |row|
          state = states[row.endpoint_origin]
          if state && state.honor_until > row.event_time
            if state.reason == 'retry_after'
              in_retry_after += 1
            elsif state.reason == 'recent_429'
              in_recent_cooldown += 1
            end
            firsts += 1 if row.first_attempt?
            retries += 1 if row.retry_attempt?
            targets[row.target_id] = true if row.target_id.present?
          end

          proposed = next_honor(row)
          next if proposed.nil?

          existing = states[row.endpoint_origin]
          if existing.nil? || proposed.honor_until > existing.honor_until
            states[row.endpoint_origin] = proposed
          end
        end

        {
          'attempts_in_retry_after_window' => in_retry_after,
          'attempts_in_recent_429_window' => in_recent_cooldown,
          'unique_targets' => targets.length,
          'first_attempts_in_window' => firsts,
          'retry_attempts_in_window' => retries,
          'note' => 'observed timestamps fall inside the candidate suppression window; this is not a full-system counterfactual that those requests would not occur',
        }
      end

      private

      def next_honor(row)
        now = row.event_time
        unless row.retry_after_seconds.nil?
          capped = [row.retry_after_seconds.to_i, @profile.max_retry_after_seconds].min
          return unless capped.positive?

          return State.new(honor_until: now + capped, reason: 'retry_after')
        end
        return unless row.http_status.to_i == 429

        cooldown = @profile.recent_429_cooldown_seconds
        return unless cooldown.positive?

        State.new(honor_until: now + cooldown, reason: 'recent_429')
      end
    end
  end
end
