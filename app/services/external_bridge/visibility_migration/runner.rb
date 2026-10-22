# frozen_string_literal: true

module ExternalBridge
  module VisibilityMigration
    # Default is dry-run. Apply writes one batch per transaction, invalidates
    # cache only after commit, and advances the checkpoint only after that.
    class Runner
      READER_NOTE = 'Preflight checked this database only. It did not detect running web or Sidekiq processes. ' \
                    'Reader readiness was an operator confirmation.'

      def self.call(raw)
        new(raw).call
      end

      def initialize(raw)
        @options = Options.build(raw)
        @counts = Hash.new(0)
        @invalid_rows = []
        @failure = nil
      end

      def call
        return verify if @options.verify?
        return apply if @options.apply?

        dry_run
      end

      private

      def dry_run
        cursor, watermark = dry_cursor
        cursor = walk(cursor, watermark, dry: true)
        finish(:dry_run, cursor, watermark)
      end

      def apply
        @checkpoint = Checkpoint.new(@options.checkpoint_path)
        @checkpoint.lease!
        begin
          open_leased_checkpoint!
          replay_pending! if @checkpoint.pending_batch
          return failed_result if @failure

          cursor = walk(@checkpoint.last_completed, @checkpoint.watermark, dry: false)
          finish(:apply, cursor, @checkpoint.watermark)
        ensure
          @checkpoint.release!
        end
      end

      def verify
        watermark = current_watermark
        cursor = walk(0, watermark, dry: true)
        return finish(:verify, cursor, watermark) unless @failure.nil? && remaining(cursor, watermark).zero? && clean_window?

        verify_again(watermark)
      end

      def verify_again(watermark)
        if current_watermark > watermark
          @counts[:watermark_moved] = 1
          @failure = :verify_remaining
          return finish(:verify, 0, watermark)
        end

        cursor = confirm_window(watermark)
        if current_watermark > watermark
          @counts[:watermark_moved] = 1
          @failure = :verify_remaining
        end
        finish(:verify, cursor, watermark)
      end

      def walk(cursor, watermark, dry:)
        while room.positive? && @failure.nil?
          if stop_requested?
            @failure = :stopped
            break
          end

          page = Scanner.page(after: cursor, watermark: watermark, user_id: @options.user_id, subscription_id: @options.subscription_id, limit: [room, @options.batch_size].min)
          break if page.empty?

          cursor = dry ? classify_page(page, cursor) : write_page(page, cursor)
          pause_between_batches
        end
        cursor
      end

      def classify_page(page, cursor)
        Classifier.new(page).classify_all.each do |row|
          break if room.zero?

          note(row)
          if row[:kind] == :invalid
            @failure = :invalid
            break
          end
          cursor = row[:marker_id]
        end
        cursor
      end

      def confirm_window(watermark)
        cursor = 0
        while room.positive? && @failure.nil?
          if stop_requested?
            @failure = :stopped
            break
          end

          page = Scanner.page(after: cursor, watermark: watermark, user_id: @options.user_id, subscription_id: @options.subscription_id, limit: [room, @options.batch_size].min)
          break if page.empty?

          Classifier.new(page).classify_all.each do |row|
            break if room.zero?

            @counts[:scanned] += 1
            cursor = row[:marker_id]
            next unless row[:kind] == :eligible || row[:kind] == :invalid

            @failure = :verify_remaining
            @counts[row[:kind]] += 1
            @invalid_rows << { marker_id: row[:marker_id], status_id: row[:status_id], reason: row[:reason] } if row[:kind] == :invalid
            break
          end
        end
        cursor
      end

      def write_page(page, cursor)
        if stop_requested?
          @failure = :stopped
          return cursor
        end

        remember_pending(page)
        hook(:before_database)
        tally = Batch.apply!(marker_ids: page.map(&:id), lock_timeout: @options.lock_timeout, statement_timeout: @options.statement_timeout)
        follow_through(page, tally)
        cursor_after(page, tally)
      rescue InvalidRow => e
        note_invalid(e, page.length)
        cursor
      rescue CacheIncomplete
        raise
      rescue StandardError => e
        raise e unless lock_error?(e)

        @failure = :lock_conflict
        cursor
      end

      def replay_pending!
        pending = @checkpoint.pending_batch
        require_pending_budget!(pending)
        if stop_requested?
          @failure = :stopped
          return
        end

        hook(:before_database)
        tally = Batch.apply!(marker_ids: pending['marker_ids'], lock_timeout: @options.lock_timeout, statement_timeout: @options.statement_timeout)
        finish_committed(pending['status_ids'], tally, pending['last_marker_id'], pending['marker_ids'].length)
      rescue InvalidRow => e
        note_invalid(e, pending['marker_ids'].length)
      rescue CacheIncomplete
        raise
      rescue StandardError => e
        raise e unless lock_error?(e)

        @failure = :lock_conflict
      end

      def require_pending_budget!(pending)
        count = pending['marker_ids'].length
        return if count <= @options.batch_size && count <= @options.limit

        raise Refusal.new(
          :pending_budget,
          "pending batch has #{count} markers. This run allows batch-size #{@options.batch_size} and limit #{@options.limit}. " \
          "Raise both to at least #{count} before resuming. Nothing was written."
        )
      end

      def follow_through(page, tally)
        finish_committed(
          page.map(&:status_id) | tally[:converted_status_ids] | tally[:already_external_status_ids],
          tally,
          page.last.id,
          page.length
        )
      end

      def finish_committed(status_ids, tally, last_marker_id, scanned)
        hook(:after_database_commit)
        deliver_cache(status_ids)
        hook(:before_checkpoint_advance)
        @checkpoint.complete_batch!(last_marker_id)
        absorb(tally, scanned)
      rescue StandardError => e
        raise e if e.is_a?(CacheIncomplete)

        raise CacheIncomplete, e.message
      end

      def deliver_cache(status_ids)
        status_ids.each_slice(CacheSync::SLICE) do |slice|
          hook(:during_cache)
          CacheSync.invalidate!(slice)
        end
      end

      def remember_pending(page)
        @checkpoint.mark_pending!(
          marker_ids: page.map(&:id),
          status_ids: page.map(&:status_id),
          first_marker_id: page.first.id,
          last_marker_id: page.last.id
        )
      end

      def note(row)
        @counts[:scanned] += 1
        case row[:kind]
        when :eligible
          @counts[:eligible] += 1
        when :already_external
          @counts[:already_external] += 1
        when :invalid
          @counts[:invalid] += 1
          @invalid_rows << { marker_id: row[:marker_id], status_id: row[:status_id], reason: row[:reason] }
        end
      end

      def note_invalid(error, scanned)
        @failure = :invalid
        @counts[:scanned] += scanned
        @counts[:invalid] += 1
        @invalid_rows << { marker_id: error.marker_id, status_id: error.status_id, reason: error.reason }
      end

      def absorb(tally, scanned)
        @counts[:scanned] += scanned
        @counts[:eligible] += tally[:eligible].to_i
        @counts[:converted] += Array(tally[:converted_status_ids]).length
        @counts[:already_external] += Array(tally[:already_external_status_ids]).length
        @counts[:concurrently_removed] += Array(tally[:removed_marker_ids]).length
      end

      def cursor_after(page, _tally)
        page.last.id
      end

      def finish(mode, cursor, watermark)
        %i(scanned eligible converted already_external concurrently_removed invalid remaining_in_window).each do |key|
          @counts[key] = @counts[key].to_i
        end
        @counts[:remaining_in_window] = remaining(cursor, watermark)
        @counts[:legacy_remaining] = @counts[:eligible] if mode == :verify
        outcome = outcome_for(mode)
        Result.new(mode: mode, outcome: outcome, counts: @counts.dup, invalid_rows: @invalid_rows, message: message_for(mode, outcome))
      end

      def failed_result
        @counts[:remaining_in_window] = remaining(@checkpoint.last_completed, @checkpoint.watermark)
        Result.new(mode: :apply, outcome: @failure, counts: @counts.dup, invalid_rows: @invalid_rows, message: message_for(:apply, @failure))
      end

      def outcome_for(mode)
        return @failure if @failure
        return :limit_reached if @counts[:remaining_in_window].positive?
        return verify_outcome if mode == :verify

        :window_complete
      end

      def verify_outcome
        return :verify_remaining if @counts[:eligible].positive? || @counts[:invalid].positive? || @counts[:watermark_moved].to_i.positive?

        filtered? ? :scope_complete : :instance_complete
      end

      def clean_window?
        @failure.nil? && @counts[:eligible].zero? && @counts[:invalid].zero?
      end

      def message_for(mode, outcome)
        text = (MESSAGES[[mode, outcome]] || MESSAGES[outcome]).to_s
        text = "#{text} #{READER_NOTE}" if mode == :apply
        text
      end

      def dry_cursor
        return [0, Scanner.watermark(user_id: @options.user_id, subscription_id: @options.subscription_id)] if @options.checkpoint_path.nil? || !File.exist?(@options.checkpoint_path)

        checkpoint = Checkpoint.new(@options.checkpoint_path).load!(@options.scope_document)
        [checkpoint.last_completed, checkpoint.watermark]
      end

      def open_leased_checkpoint!
        if File.file?(@checkpoint.path)
          @checkpoint.load!(@options.scope_document)
        else
          @checkpoint.create!(@options.scope_document, Scanner.watermark(user_id: @options.user_id, subscription_id: @options.subscription_id))
        end
      end

      def remaining(cursor, watermark)
        Scanner.remaining(after: cursor, watermark: watermark, user_id: @options.user_id, subscription_id: @options.subscription_id)
      end

      def room
        @options.limit - @counts[:scanned]
      end

      def filtered?
        @options.user_id || @options.subscription_id
      end

      def stop_requested?
        return true if @stop_requested

        @stop_requested = @options.stop_check&.call ? true : false
      end

      def current_watermark
        Scanner.watermark(user_id: @options.user_id, subscription_id: @options.subscription_id)
      end

      def pause_between_batches
        sleep(@options.pause) if @options.pause.positive? && @failure.nil?
      end

      def hook(name)
        @options.injector&.call(name)
      end

      def lock_error?(error)
        cause = error
        while cause
          return true if cause.is_a?(PG::LockNotAvailable) || cause.is_a?(PG::QueryCanceled) || cause.is_a?(PG::TRDeadlockDetected)
          return true if cause.respond_to?(:sqlstate) && %w(55P03 57014 40P01).include?(cause.sqlstate)

          cause = cause.cause
        end
        false
      end

      MESSAGES = {
        [:dry_run, :window_complete] => 'Dry-run finished this window. Nothing was written. This is not instance completion.',
        [:dry_run, :limit_reached] => 'Dry-run stopped because the scan limit was reached. Nothing was written. The window is not complete.',
        [:dry_run, :stopped] => 'Dry-run stopped before the window was complete. Nothing was written.',
        [:dry_run, :invalid] => 'Dry-run stopped on a row that cannot be migrated. Nothing was written.',
        [:apply, :window_complete] => 'Apply finished this checkpoint window. This is not instance completion. Run --verify after writers are quiet.',
        [:apply, :limit_reached] => 'Apply stopped because the scan limit was reached. Resume the same checkpoint. The window is not complete.',
        [:apply, :stopped] => 'Apply stopped by signal. Resume the same checkpoint. The window is not complete.',
        [:apply, :invalid] => 'Apply rolled the batch back and stopped. A row is not a valid legacy or external projection. The checkpoint did not skip it.',
        [:apply, :lock_conflict] => 'Apply stopped because a row lock or statement timeout fired. The checkpoint did not skip that row.',
        [:apply, :cache_incomplete] => 'Rows were committed and cache follow-up did not finish. Resume the same checkpoint to retry cache work, including rows already external.',
        [:verify, :scope_complete] => 'Verify found no legacy or invalid projection in this scope. This is not instance completion.',
        [:verify, :instance_complete] => 'Verify found no legacy or invalid projection in this instance window.',
        [:verify, :verify_remaining] => 'Verify is not complete. Legacy rows, invalid rows, or a moved marker watermark remain.',
        [:verify, :limit_reached] => 'Verify stopped because the scan limit was reached. A clean verify reads the window twice, and both reads count toward --limit. This is not completion.',
        [:verify, :invalid] => 'Verify found an invalid projection. This is not completion.',
        :window_complete => 'The window is complete. This is not instance completion.',
        :limit_reached => 'Stopped because the scan limit was reached.',
        :stopped => 'Stopped before the window was complete.',
        :invalid => 'Stopped on a row that cannot be migrated.',
        :lock_conflict => 'Stopped on a row lock. The checkpoint did not skip that row.',
        :verify_remaining => 'Verify is not complete.',
        :scope_complete => 'Scope verify is clean. This is not instance completion.',
        :instance_complete => 'Instance verify is clean.',
      }.freeze

      class CacheIncomplete < StandardError; end
    end
  end
end
