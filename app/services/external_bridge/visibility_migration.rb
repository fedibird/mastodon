# frozen_string_literal: true

module ExternalBridge
  # Forward-only operator migration of projection statuses from visibility 200
  # to 201. Marker ids drive a bounded keyset. Ordinary personal rows are not
  # candidates. Nothing here reverses an external row.
  module VisibilityMigration
    DIRECTION = 'personal_to_external'
    CHECKPOINT_VERSION = 1

    class Refusal < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    class InvalidRow < StandardError
      attr_reader :marker_id, :status_id, :reason

      def initialize(marker_id, status_id, reason)
        @marker_id = marker_id
        @status_id = status_id
        @reason = reason
        super("invalid marker=#{marker_id} status=#{status_id} reason=#{reason}")
      end
    end

    class Result
      attr_reader :mode, :outcome, :counts, :invalid_rows, :message

      def initialize(mode:, outcome:, counts:, invalid_rows:, message:)
        @mode = mode
        @outcome = outcome
        @counts = counts
        @invalid_rows = invalid_rows
        @message = message
      end

      def exit_code
        case outcome
        when :window_complete, :scope_complete, :instance_complete
          0
        when :limit_reached
          2
        when :stopped
          3
        when :invalid, :lock_conflict
          4
        when :verify_remaining
          5
        when :cache_incomplete
          6
        else
          1
        end
      end

      def to_s
        lines = ["#{mode} #{outcome}: #{message}"]
        counts.each { |key, value| lines << "#{key}: #{value}" }
        invalid_rows.each do |row|
          lines << "invalid marker=#{row[:marker_id]} status=#{row[:status_id]} reason=#{row[:reason]}"
        end
        lines.join("\n")
      end
    end
  end
end
