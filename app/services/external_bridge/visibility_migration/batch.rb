# frozen_string_literal: true

module ExternalBridge
  module VisibilityMigration
    # One short transaction. Markers are locked in id order, then statuses in
    # id order, matching the import path which updates the marker before the
    # status. Purge locks the status first; a deadlock or lock_timeout aborts
    # this transaction and the checkpoint does not move past the row.
    class Batch
      def self.apply!(marker_ids:, lock_timeout:, statement_timeout:)
        new(marker_ids, lock_timeout, statement_timeout).apply!
      end

      def initialize(marker_ids, lock_timeout, statement_timeout)
        @marker_ids = marker_ids.map { |id| Integer(id) }
        @lock_timeout = lock_timeout
        @statement_timeout = statement_timeout
        @current_status_id = nil
        @current_marker_id = nil
      end

      def apply!
        tally = nil
        ApplicationRecord.transaction(requires_new: true) do
          with_timeouts { tally = convert_locked_rows }
        end
        tally
      rescue InvalidRow
        raise
      rescue StandardError => e
        raise e unless constraint_violation?(e)

        raise InvalidRow.new(@current_marker_id, @current_status_id, :transition_rejected)
      end

      private

      def convert_locked_rows
        locked = lock_markers
        missing = @marker_ids - locked.map(&:id)
        lock_statuses(locked)
        classified = Classifier.new(locked).classify_all
        invalid = classified.find { |row| row[:kind] == :invalid }
        raise InvalidRow.new(invalid[:marker_id], invalid[:status_id], invalid[:reason]) if invalid

        converted = convert_eligible(classified)
        tally(classified, converted, missing)
      end

      def lock_markers
        return [] if @marker_ids.empty?

        list = @marker_ids.join(',')
        sql = <<~SQL
          SELECT id, status_id, user_id, account_id, external_source_id,
                 external_subscription_id, external_resource_id
          FROM external_status_projections
          WHERE id IN (#{list})
          ORDER BY id
          FOR NO KEY UPDATE
        SQL
        ActiveRecord::Base.connection.select_all(sql).map { |row| Marker.new(row) }
      end

      def lock_statuses(markers)
        ids = markers.map(&:status_id).uniq.sort
        return if ids.empty?

        ActiveRecord::Base.connection.select_values(<<~SQL)
          SELECT id FROM statuses
          WHERE id IN (#{ids.join(',')})
          ORDER BY id
          FOR NO KEY UPDATE
        SQL
      end

      def convert_eligible(classified)
        converted = []
        classified.each do |row|
          next unless row[:kind] == :eligible

          @current_marker_id = row[:marker_id]
          @current_status_id = row[:status_id]
          updated = Integer(ActiveRecord::Base.connection.select_value("SELECT external_visibility_migrate_status(#{row[:status_id].to_i})"))
          raise InvalidRow.new(row[:marker_id], row[:status_id], :transition_rejected) unless updated == 1

          converted << row[:status_id]
        end
        converted
      end

      def tally(classified, converted, missing_marker_ids)
        {
          scanned: @marker_ids.length,
          eligible: classified.count { |row| row[:kind] == :eligible },
          converted_status_ids: converted,
          already_external_status_ids: classified.select { |row| row[:kind] == :already_external }.map { |row| row[:status_id] },
          removed_marker_ids: missing_marker_ids,
        }
      end

      def with_timeouts
        connection = ActiveRecord::Base.connection
        previous_lock = connection.select_value("SELECT current_setting('lock_timeout')")
        previous_statement = connection.select_value("SELECT current_setting('statement_timeout')")
        connection.execute("SET LOCAL lock_timeout = #{connection.quote(@lock_timeout)}")
        connection.execute("SET LOCAL statement_timeout = #{connection.quote(@statement_timeout)}")
        result = yield
        connection.execute("SET LOCAL lock_timeout = #{connection.quote(previous_lock)}")
        connection.execute("SET LOCAL statement_timeout = #{connection.quote(previous_statement)}")
        result
      end

      def constraint_violation?(error)
        cause = error
        while cause
          return true if cause.is_a?(PG::CheckViolation)
          return true if cause.respond_to?(:sqlstate) && cause.sqlstate == '23514'

          cause = cause.cause
        end
        false
      end

      # Plain row from select_all. Strings keys, integer-ish values.
      class Marker
        attr_reader :id, :status_id, :user_id, :account_id, :external_source_id,
                    :external_subscription_id, :external_resource_id

        def initialize(row)
          @id = integer(row, 'id')
          @status_id = integer(row, 'status_id')
          @user_id = integer(row, 'user_id')
          @account_id = integer(row, 'account_id')
          @external_source_id = integer(row, 'external_source_id')
          @external_subscription_id = integer(row, 'external_subscription_id')
          @external_resource_id = integer(row, 'external_resource_id')
        end

        def integer(row, key)
          Integer(row[key] || row[key.to_sym])
        end
      end
    end
  end
end
