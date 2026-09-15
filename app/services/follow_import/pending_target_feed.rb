# frozen_string_literal: true

# Bounded pending-target walker for one batch. Loads a small window at a
# time (ORDER BY position, id) so a 20k batch is never fully materialized
# to build a 50-row shadow plan. No FOR UPDATE.
#
# after_position is reconstructable simulation state only. Targets remain
# pending and may be planned again after wrap-around.
module FollowImport
  class PendingTargetFeed
    WINDOW = 8

    def initialize(batch_id, after_position: nil, window: WINDOW)
      @batch_id = batch_id
      @after_position = after_position
      @started_after = after_position
      @window = window
      @buffer = []
      @done = false
      # Wrap only when this tick started mid-batch. Starting from the
      # head must not re-yield the same pending rows after exhaustion.
      @wrapped = after_position.nil?
      @wrap_ceiling = nil
    end

    def shift
      fill if @buffer.empty? && !@done
      record = @buffer.shift
      return if record.nil?

      {
        id: record.id,
        position: record.position,
        destination_domain: record.destination_domain,
      }
    end

    def remaining?
      fill if @buffer.empty? && !@done
      @buffer.any?
    end

    private

    def fill
      return if @done

      rows = fetch_window(@after_position)
      if rows.empty? && @started_after && !@wrapped
        @wrap_ceiling = @started_after
        @after_position = nil
        @wrapped = true
        rows = fetch_window(nil)
      end

      if rows.empty?
        @done = true
        return
      end

      @after_position = rows.last.position
      @buffer.concat(rows)
    end

    def fetch_window(after_position)
      scope = FollowImportTarget.where(batch_id: @batch_id, state: :pending).order(:position, :id)
      scope = scope.where('position > ?', after_position) unless after_position.nil?
      scope = scope.where('position <= ?', @wrap_ceiling) unless @wrap_ceiling.nil?
      scope.limit(@window).to_a
    end
  end
end
