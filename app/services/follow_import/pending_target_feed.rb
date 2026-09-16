# frozen_string_literal: true

# Bounded pending-target walker for one batch. Loads a small window at a
# time (ORDER BY position, id) so a 20k batch is never fully materialized
# to build a 50-row plan. No FOR UPDATE. No one-row SELECT.
#
# remaining? and shift both fill. FairScheduler must not call remaining?
# on every owner/batch before planning; touch a feed only when that
# owner receives a scheduling opportunity.
#
# after_position is reconstructable simulation state only. Targets remain
# pending and may be planned again after wrap-around.
#
# When a scan policy is supplied, this feed inspects at most
# max_targets / max_windows rows/windows in one tick. A window query is
# never larger than the remaining target budget. "inspected" is a
# successful shift; "loaded" is rows fetched into the buffer.
#
# last_inspected_position advances on every inspected row, including
# admission-blocked pending rows. That is not completion.
#
# An empty tail probe (position > cursor, zero rows) is not a logical
# candidate window. If this tick started mid-batch it may wrap and
# fetch the head even when max_windows_per_batch is 1. That wrap+head
# fetch counts as one window. Otherwise a cursor parked at the last
# pending position would spend every tick on the empty tail and never
# reconsider earlier rows.
module FollowImport
  class PendingTargetFeed
    WINDOW = 8

    attr_reader :targets_scanned, :windows_scanned, :last_inspected_position

    def initialize(batch_id, after_position: nil, window: WINDOW, max_targets: nil, max_windows: nil)
      @batch_id = batch_id
      @after_position = after_position
      @started_after = after_position
      @window = window
      @max_targets = max_targets
      @max_windows = max_windows
      @buffer = []
      @done = false
      # Wrap only when this tick started mid-batch. Starting from the
      # head must not re-yield the same pending rows after exhaustion.
      @wrapped = after_position.nil?
      @wrap_ceiling = nil
      @targets_scanned = 0
      @windows_scanned = 0
      @last_inspected_position = after_position
      @scan_budget_exhausted = false
    end

    def shift
      return if scan_budget_exhausted?

      fill if @buffer.empty? && !@done
      record = @buffer.shift
      return if record.nil?

      @targets_scanned += 1
      @last_inspected_position = record.position
      if @max_targets && @targets_scanned >= @max_targets
        @scan_budget_exhausted = true
        @done = true
      end

      {
        id: record.id,
        position: record.position,
        destination_domain: record.destination_domain,
      }
    end

    def remaining?
      return false if scan_budget_exhausted?

      fill if @buffer.empty? && !@done
      @buffer.any?
    end

    def scan_budget_exhausted?
      @scan_budget_exhausted
    end

    private

    def fill
      return if @done

      if remaining_target_budget <= 0 || window_budget_exhausted?
        @scan_budget_exhausted = true
        @done = true
        return
      end

      rows = fetch_window(@after_position, current_limit)
      if rows.empty? && wrap_available?
        begin_wrap
        rows = fetch_counted_window(nil)
      elsif rows.any?
        record_window
      else
        @done = true
        return
      end

      if rows.empty?
        @done = true
        return
      end

      @after_position = rows.last.position
      @buffer.concat(rows)
    end

    def wrap_available?
      @started_after && !@wrapped
    end

    def begin_wrap
      @wrap_ceiling = @started_after
      @after_position = nil
      @wrapped = true
    end

    def fetch_counted_window(after_position)
      record_window
      fetch_window(after_position, current_limit)
    end

    def record_window
      @windows_scanned += 1
    end

    def current_limit
      [@window, remaining_target_budget].min
    end

    def fetch_window(after_position, limit)
      return [] if limit <= 0

      scope = FollowImportTarget.where(batch_id: @batch_id, state: :pending).order(:position, :id)
      scope = scope.where('position > ?', after_position) unless after_position.nil?
      scope = scope.where('position <= ?', @wrap_ceiling) unless @wrap_ceiling.nil?
      scope.limit(limit).to_a
    end

    def remaining_target_budget
      return @window unless @max_targets

      left = @max_targets - @targets_scanned - @buffer.size
      left.positive? ? left : 0
    end

    def window_budget_exhausted?
      @max_windows && @windows_scanned >= @max_windows
    end
  end
end
