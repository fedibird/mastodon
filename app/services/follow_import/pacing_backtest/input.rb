# frozen_string_literal: true

require 'csv'

# CSV loaders for exported Follow Import telemetry. Extra columns are
# ignored. Required transport headers must be present; missing cells are
# not coerced to zero.
module FollowImport
  class PacingBacktest
    class Input
      REQUIRED_TRANSPORT_HEADERS = %w(
        target_id
        phase
        destination_domain
        endpoint_origin
        started_at
        finished_at
        request_started_at
        request_finished_at
        enqueued_at
        queue_wait_ms
        request_duration_ms
        outcome
        http_status
        retry_after_seconds
        error_class
      ).freeze

      REQUIRED_TICK_HEADERS = %w(observed_at).freeze
      REQUIRED_DISPATCH_HEADERS = %w(observed_at).freeze

      Dataset = Struct.new(
        :rows,
        :delivery_rows,
        :timed_rows,
        :ticks,
        :dispatch_passes,
        :malformed_counts,
        :missing_target_id_count,
        :input_files,
        :warnings,
        keyword_init: true
      )

      def self.load(**paths)
        new(paths).load
      end

      def initialize(paths)
        @paths = paths
        @malformed_counts = Hash.new(0)
        @warnings = []
      end

      def load
        transport_path = required_file(:transport, 'TRANSPORT')
        rows = load_transport(transport_path)
        delivery_rows = rows.select(&:delivery?)
        raise FollowImport::PacingBacktest::Error, 'no usable activitypub_delivery rows' if delivery_rows.empty?

        assign_ordinals!(delivery_rows)
        timed_rows = delivery_rows.select(&:timed?).sort_by { |row| [row.event_time.to_f, row.row_number] }

        Dataset.new(
          rows: rows,
          delivery_rows: delivery_rows,
          timed_rows: timed_rows,
          ticks: optional_table(:ticks, 'TICKS', REQUIRED_TICK_HEADERS),
          dispatch_passes: optional_table(:dispatch, 'DISPATCH', REQUIRED_DISPATCH_HEADERS),
          malformed_counts: @malformed_counts.dup,
          missing_target_id_count: delivery_rows.count { |row| row.target_id.blank? },
          input_files: input_files,
          warnings: @warnings.dup
        )
      end

      private

      def input_files
        {
          'transport' => basename(@paths[:transport]),
          'scenarios' => basename(@paths[:scenarios]),
          'ticks' => basename(@paths[:ticks]),
          'dispatch' => basename(@paths[:dispatch]),
        }
      end

      def basename(path)
        return if path.to_s.strip.empty?

        File.basename(path)
      end

      def required_file(key, env_name)
        path = @paths[key].to_s
        raise FollowImport::PacingBacktest::Error, "missing required input file (#{env_name})" if path.strip.empty?
        raise FollowImport::PacingBacktest::Error, "missing required input file (#{env_name}): #{path}" unless File.file?(path)

        path
      end

      def optional_table(key, env_name, required_headers)
        path = @paths[key].to_s
        if path.strip.empty?
          @warnings << "#{env_name} not supplied; corresponding sections are unavailable rather than zero"
          return nil
        end
        unless File.file?(path)
          raise FollowImport::PacingBacktest::Error, "optional input file not found (#{env_name}): #{path}"
        end

        read_generic(path, required_headers)
      end

      def load_transport(path)
        table = read_table(path)
        headers = Array(table.headers).map(&:to_s)
        missing = REQUIRED_TRANSPORT_HEADERS - headers
        unless missing.empty?
          raise FollowImport::PacingBacktest::Error, "missing required transport headers: #{missing.join(', ')}"
        end

        table.each_with_index.map { |row, index| build_attempt(row, index + 1) }
      end

      def build_attempt(row, row_number)
        malformed = []
        request_started_at = parse_time(row['request_started_at'], 'request_started_at', malformed)
        started_at = parse_time(row['started_at'], 'started_at', malformed)
        event_time = request_started_at || started_at
        attempt = Attempt.new(
          row_number: row_number,
          phase: blank_to_nil(row['phase']),
          target_id: blank_to_nil(row['target_id']),
          destination_domain: blank_to_nil(row['destination_domain']),
          endpoint_origin: blank_to_nil(row['endpoint_origin']),
          started_at: started_at,
          finished_at: parse_time(row['finished_at'], 'finished_at', malformed),
          request_started_at: request_started_at,
          request_finished_at: parse_time(row['request_finished_at'], 'request_finished_at', malformed),
          enqueued_at: parse_time(row['enqueued_at'], 'enqueued_at', malformed),
          queue_wait_ms: parse_int(row['queue_wait_ms'], 'queue_wait_ms', malformed),
          request_duration_ms: parse_int(row['request_duration_ms'], 'request_duration_ms', malformed),
          outcome: blank_to_nil(row['outcome']),
          http_status: parse_int(row['http_status'], 'http_status', malformed),
          retry_after_seconds: parse_int(row['retry_after_seconds'], 'retry_after_seconds', malformed),
          error_class: blank_to_nil(row['error_class']),
          event_time: event_time,
          attempt_ordinal: nil,
          malformed_fields: malformed.uniq
        )
        record_malformed(attempt.malformed_fields)
        attempt
      end

      def assign_ordinals!(rows)
        grouped = Hash.new { |hash, key| hash[key] = [] }
        rows.each do |row|
          next if row.target_id.blank? || !row.timed?

          grouped[row.target_id] << row
        end
        grouped.each_value do |list|
          list.sort_by { |row| [row.event_time.to_f, row.row_number] }
              .each_with_index { |row, index| row.attempt_ordinal = index + 1 }
        end
      end

      def read_generic(path, required_headers)
        table = read_table(path)
        headers = Array(table.headers).map(&:to_s)
        missing = required_headers - headers
        unless missing.empty?
          raise FollowImport::PacingBacktest::Error, "missing required headers in #{File.basename(path)}: #{missing.join(', ')}"
        end

        table.each_with_index.map do |row, index|
          GenericRow.new(index + 1, table.headers, row, @malformed_counts)
        end
      end

      def read_table(path)
        CSV.parse(File.read(path, encoding: 'bom|utf-8'), headers: true)
      rescue CSV::MalformedCSVError => e
        raise FollowImport::PacingBacktest::Error, "invalid CSV (#{File.basename(path)}): #{e.message}"
      end

      def parse_time(value, field, malformed)
        return if blank_to_nil(value).nil?

        parsed = FollowImport::ObservationTime.parse(value)
        if parsed.nil?
          malformed << field
          return
        end

        parsed
      end

      def parse_int(value, field, malformed)
        return if blank_to_nil(value).nil?

        Integer(value.to_s.strip)
      rescue ArgumentError, TypeError
        malformed << field
        nil
      end

      def blank_to_nil(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def record_malformed(fields)
        fields.uniq.each { |field| @malformed_counts[field] += 1 }
      end

      class GenericRow
        attr_reader :row_number, :values

        def initialize(row_number, headers, row, malformed_counts)
          @row_number = row_number
          @values = {}
          headers.each do |header|
            @values[header] = row[header]
          end
          @malformed_counts = malformed_counts
        end

        def [](key)
          @values[key.to_s]
        end

        def time(key)
          raw = self[key]
          return if raw.to_s.strip.empty?

          parsed = FollowImport::ObservationTime.parse(raw)
          if parsed.nil?
            @malformed_counts[key.to_s] += 1
            return
          end
          parsed
        end

        def int(key)
          raw = self[key]
          return if raw.to_s.strip.empty?

          Integer(raw.to_s.strip)
        rescue ArgumentError, TypeError
          @malformed_counts[key.to_s] += 1
          nil
        end
      end
    end
  end
end
