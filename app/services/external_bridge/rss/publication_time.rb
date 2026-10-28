# frozen_string_literal: true

module ExternalBridge
  module RSS
    # The instant stored on a new projection, and the only parser for feed dates.
    #
    # A well-formed publication instant that is strictly before now becomes
    # Status.created_at. Snowflake::Callbacks then mints the id from that
    # column. updated_at stays the save clock. override_timestamps is not set.
    #
    # Future instants fall back to ExternalResource.created_at, the first
    # observation. There is no grace period. Snowflake::Callbacks already
    # refuses created_at >= now by minting an insertion-time id, and a
    # tolerance would widen that rule and could issue unbounded future ids.
    # The feed's own instant remains on ExternalResource.published_at.
    #
    # Missing, unparsable, pre-epoch, and signed-bigint-overflow instants use
    # the same first observation. fetched_at changes on every poll and is
    # never a fallback. lastBuildDate and HTTP Last-Modified are not read.
    #
    # The chosen created_at is not rewritten when a later poll corrects or
    # drops the feed date. The status id stays. Display order therefore keeps
    # matching id order. The corrected instant stays on the resource only.
    class PublicationTime
      # id_at adds up to 999 ms and a 16-bit tail. The whole value must fit
      # in a signed bigint even in that worst case.
      SNOWFLAKE_TAIL = (2**16) - 1
      SNOWFLAKE_RANDOM_MS = 999
      MAX_UNIX_MS = (((2**63) - 1 - SNOWFLAKE_TAIL) >> 16) - SNOWFLAKE_RANDOM_MS
      EPOCH = Time.utc(1970, 1, 1)

      ISO8601 = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:\d{2})\z/
      RFC822 = /\A(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun),\s+)?(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s+(?:UT|GMT|EST|EDT|CST|CDT|MST|MDT|PST|PDT|Z|[+-]\d{4})\z/i
      MONTHS = {
        'jan' => 1, 'feb' => 2, 'mar' => 3, 'apr' => 4, 'may' => 5, 'jun' => 6,
        'jul' => 7, 'aug' => 8, 'sep' => 9, 'oct' => 10, 'nov' => 11, 'dec' => 12
      }.freeze

      class << self
        def parse(value)
          text = value.to_s.strip
          return nil if text.blank? || text.bytesize > 64

          if (match = ISO8601.match(text))
            return iso8601(text, match)
          end

          if (match = RFC822.match(text))
            return rfc822(text, match)
          end

          nil
        end

        def for_new_status(resource, now: Time.current)
          published = resource&.published_at
          return resource&.created_at unless usable_status_instant?(published, now)

          published
        end

        def usable_status_instant?(time, now = Time.current)
          return false if time.blank?

          instant = time.to_time.utc
          return false if instant >= now.to_time.utc
          return false if instant < EPOCH

          (instant.to_i * 1000) <= MAX_UNIX_MS
        rescue StandardError
          false
        end

        private

        def iso8601(text, match)
          parsed = Time.iso8601(text)
          wall = parsed.getlocal(parsed.utc_offset)
          return nil unless wall_matches?(wall, [match[1], match[2], match[3], match[4], match[5], match[6]])

          parsed.in_time_zone
        rescue ArgumentError, TypeError
          nil
        end

        def rfc822(text, match)
          parsed = Time.rfc2822(text)
          second = match[6].nil? ? 0 : match[6]
          wall = parsed.getlocal(parsed.utc_offset)
          return nil unless wall_matches?(wall, [match[3], MONTHS.fetch(match[2].downcase), match[1], match[4], match[5], second])

          parsed.in_time_zone
        rescue ArgumentError, TypeError, KeyError
          nil
        end

        def wall_matches?(wall, parts)
          year, month, day, hour, minute, second = parts.map(&:to_i)
          wall.year == year && wall.month == month && wall.day == day &&
            wall.hour == hour && wall.min == minute && wall.sec == second
        end
      end
    end
  end
end
