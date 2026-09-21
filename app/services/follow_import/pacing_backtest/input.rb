# frozen_string_literal: true

require 'csv'

# CSV loaders for exported Follow Import telemetry. Extra columns are
# ignored. Required transport headers must be present; missing cells are
# not coerced to zero. Optional tick/dispatch fields are parsed once at
# load time so malformed counts are complete and deterministic.
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
      TICK_INT_FIELDS = %w(
        planned_count
        claimed_count
        global_base_budget
        effective_global_budget
        global_pending_count
        historical_pending_count
        operational_pending_count
        planning_pending_count
      ).freeze
      DISPATCH_INT_FIELDS = %w(
        claimed_count
        candidate_count
        global_pending_count
        active_batch_count
      ).freeze

      Dataset = Struct.new(
        :rows,
        :delivery_rows,
        :timed_rows,
        :http_rows,
        :ticks,
        :dispatch_passes,
        :malformed_counts,
        :missing_target_id_count,
        :input_files,
        :warnings,
        keyword_init: true
      )

      OptionalTable = Struct.new(:headers, :rows, keyword_init: true) do
        def column?(name)
          headers.include?(name.to_s)
        end

        def empty?
          rows.empty?
        end

        def length
          rows.length
        end

        def map(&block)
          rows.map(&block)
        end

        def each(&block)
          rows.each(&block)
        end
      end

      ParsedRow = Struct.new(:row_number, :raw, :times, :ints, :headers, keyword_init: true) do
        def [](key)
          raw[key.to_s]
        end

        def time(key)
          times[key.to_s]
        end

        def int(key)
          ints[key.to_s]
        end

        def observed_at
          time('observed_at')
        end
      end

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
        raise FollowImport::PacingBacktest::Error, 'no usable timed activitypub_delivery rows' if timed_rows.empty?

        Dataset.new(
          rows: rows,
          delivery_rows: delivery_rows,
          timed_rows: timed_rows,
          http_rows: timed_rows.select(&:http?),
          ticks: optional_table(:ticks, 'TICKS', REQUIRED_TICK_HEADERS, TICK_INT_FIELDS),
          dispatch_passes: optional_table(:dispatch, 'DISPATCH', REQUIRED_DISPATCH_HEADERS, DISPATCH_INT_FIELDS),
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

      def optional_table(key, env_name, required_headers, int_fields)
        path = @paths[key].to_s
        if path.strip.empty?
          @warnings << "#{env_name} not supplied; corresponding sections are unavailable rather than zero"
          return nil
        end
        unless File.file?(path)
          raise FollowImport::PacingBacktest::Error, "optional input file not found (#{env_name}): #{path}"
        end

        read_optional(path, env_name.downcase, required_headers, int_fields)
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

      def read_optional(path, prefix, required_headers, int_fields)
        table = read_table(path)
        headers = Array(table.headers).map(&:to_s)
        missing = required_headers - headers
        unless missing.empty?
          raise FollowImport::PacingBacktest::Error, "missing required headers in #{File.basename(path)}: #{missing.join(', ')}"
        end

        rows = table.each_with_index.map do |row, index|
          parse_optional_row(row, index + 1, headers, prefix, int_fields)
        end
        OptionalTable.new(headers: headers, rows: rows)
      end

      def parse_optional_row(row, row_number, headers, prefix, int_fields)
        raw = {}
        headers.each { |header| raw[header] = row[header] }
        malformed = []
        times = { 'observed_at' => parse_time(raw['observed_at'], "#{prefix}.observed_at", malformed) }
        ints = {}
        int_fields.each do |field|
          next unless headers.include?(field)

          ints[field] = parse_int(raw[field], "#{prefix}.#{field}", malformed)
        end
        record_malformed(malformed)
        ParsedRow.new(row_number: row_number, raw: raw, times: times, ints: ints, headers: headers)
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
    end
  end
end
