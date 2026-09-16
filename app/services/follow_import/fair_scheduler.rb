# frozen_string_literal: true

# Equal-cost account-first rotating round-robin (unit-cost DRR).
#
# Hierarchy: owner → batch → target. Top-level peers are owners, never
# batches. Splitting one CSV into many batches cannot increase an
# owner's share. ACCOUNT_FLOOR / ACCOUNT_CAP are not invented here.
#
# Target feeds are lazy: the owner list is rotated without probing
# remaining? on every feed. A feed is touched only when that owner
# receives a scheduling opportunity. Stale/empty feeds are skipped and
# the pass continues. Termination is progress-based, not a global
# pre-scan. Complexity is the plan budget plus stale candidates, not
# the full active-owner population.
#
# Pure algorithm: given synthetic owners/batches/targets, a cursor, and
# an admission object, returns a deterministic plan. No Sidekiq, Redis,
# or ActiveRecord.
#
# Admission is asked "may I plan this candidate?" per inspected row.
# Remote-blocked rows stay pending and do not consume the global claim
# budget. The planner keeps looking for healthy later rows until the
# configured scan budget is exhausted, then returns unused share
# upward (batch → account → other accounts).
#
# Cursor distinction (FairnessCursor is reconstructable simulation
# state, not a work ledger):
#   - last_owner_key / last_batch_by_owner: who received a planned slot.
#     An owner does not get an extra top-level share because many of
#     its candidates were blocked.
#   - last_position_by_batch: how far this tick inspected inside that
#     batch, including destination-cap / origin-cap / Retry-After /
#     recent-429 / UnavailableDomain skips. Advancing this cursor is
#     not completion. The skipped row stays pending and wrap/rebuild
#     makes it eligible again after backoff expires.
module FollowImport
  class FairScheduler
    ALGORITHM      = 'account_first_rr'
    SCHEMA_VERSION = 3

    Entry = Struct.new(:owner_key, :batch_id, :target_id, :position, :destination_domain, keyword_init: true)
    Result = Struct.new(:planned, :next_cursor, :admission_stats, keyword_init: true)

    class Batch
      attr_reader :id, :feed

      def initialize(id, feed)
        @id = id
        @feed = feed
      end

      def take
        @feed.shift
      end

      def scan_budget_exhausted?
        @feed.respond_to?(:scan_budget_exhausted?) && @feed.scan_budget_exhausted?
      end

      def windows_scanned
        @feed.respond_to?(:windows_scanned) ? @feed.windows_scanned.to_i : 0
      end
    end

    class Owner
      attr_reader :key, :batches

      def initialize(key, batches)
        @key = key.to_s
        @batches = batches
        @index = 0
        @exhausted_ids = {}
      end

      def each_candidate_batch
        return if @batches.empty?

        @batches.size.times do
          batch = @batches[@index]
          @index = (@index + 1) % @batches.size
          next if @exhausted_ids[batch.id]

          yield batch
        end
      end

      def mark_exhausted(batch)
        @exhausted_ids[batch.id] = true
      end
    end

    class ArrayFeed
      attr_reader :targets_scanned, :windows_scanned, :last_inspected_position

      def initialize(rows, max_targets: nil, max_windows: nil, window: 8)
        @rows = rows.dup
        @max_targets = max_targets
        @max_windows = max_windows
        @window = window
        @targets_scanned = 0
        @windows_scanned = 0
        @last_inspected_position = nil
        @exhausted = false
      end

      def shift
        return if scan_budget_exhausted?

        start_window_if_needed
        return if scan_budget_exhausted?

        row = @rows.shift
        return if row.nil?

        @targets_scanned += 1
        @last_inspected_position = row[:position]
        @exhausted = true if @max_targets && @targets_scanned >= @max_targets
        row
      end

      def remaining?
        !scan_budget_exhausted? && @rows.any?
      end

      def scan_budget_exhausted?
        return true if @exhausted
        return true if @max_targets && @targets_scanned >= @max_targets

        false
      end

      private

      def start_window_if_needed
        return unless (@targets_scanned % @window).zero?
        return if @rows.empty?

        if @max_windows && @windows_scanned >= @max_windows
          @exhausted = true
          return
        end

        @windows_scanned += 1
      end
    end

    def self.rotate_after(items, last_key, key_fn, numeric: false)
      ordered = items.sort_by { |item| numeric ? key_fn.call(item).to_i : key_fn.call(item).to_s }
      return ordered if last_key.blank?

      index = ordered.find_index do |item|
        current = key_fn.call(item)
        numeric ? current.to_i > last_key.to_i : current.to_s > last_key.to_s
      end
      index ? ordered.rotate(index) : ordered
    end

    def initialize(budget:, owners:, cursor: FollowImport::FairnessCursor::State.empty, admission: nil, scan_policy: nil)
      @budget = budget.to_i
      @owners = owners
      @cursor = cursor
      @admission = admission || FollowImport::RemoteAdmission::NullAdmission.new
      @scan_policy = scan_policy
      @inspected_by_batch = Hash.new(0)
      @scan_exhausted_recorded = {}
      @scanned_target_count = 0
      @windows_scanned = 0
      @scan_budget_exhausted_count = 0
    end

    def plan
      entries = []
      return result_for(entries) if @budget <= 0

      last_owner = @cursor.last_owner_key
      last_batch_by_owner = @cursor.last_batch_by_owner.dup
      last_position_by_batch = @cursor.last_position_by_batch.dup
      owners = prepared_owners

      while entries.size < @budget
        progressed = false

        owners.each do |owner|
          break if entries.size >= @budget

          batch, target = take_from_owner(owner, last_position_by_batch)
          next if target.nil?

          entries << Entry.new(
            owner_key: owner.key,
            batch_id: batch.id,
            target_id: target[:id],
            position: target[:position],
            destination_domain: target[:destination_domain]
          )
          last_owner = owner.key
          last_batch_by_owner[owner.key] = batch.id
          progressed = true
        end

        break unless progressed
      end

      result_for(
        entries,
        last_owner_key: last_owner,
        last_batch_by_owner: last_batch_by_owner,
        last_position_by_batch: last_position_by_batch
      )
    end

    private

    def prepared_owners
      prepared = @owners.map do |owner|
        batches = self.class.rotate_after(
          owner[:batches],
          @cursor.last_batch_by_owner[owner[:key].to_s],
          ->(batch) { batch[:id] },
          numeric: true
        )
        Owner.new(owner[:key], batches.map { |batch| Batch.new(batch[:id], batch[:feed]) })
      end
      self.class.rotate_after(prepared, @cursor.last_owner_key, ->(owner) { owner.key })
    end

    def take_from_owner(owner, last_position_by_batch)
      selected_batch = nil
      selected_target = nil

      owner.each_candidate_batch do |batch|
        target = take_admissible(batch, last_position_by_batch)
        if target.nil?
          owner.mark_exhausted(batch)
          next
        end

        selected_batch = batch
        selected_target = target
        break
      end

      return if selected_target.nil?

      [selected_batch, selected_target]
    end

    def take_admissible(batch, last_position_by_batch)
      loop do
        if batch_scan_exhausted?(batch)
          record_scan_exhausted(batch)
          return
        end

        windows_before = batch.windows_scanned
        target = batch.take
        @windows_scanned += [batch.windows_scanned - windows_before, 0].max
        if target.nil?
          record_scan_exhausted(batch) if batch.scan_budget_exhausted?
          return
        end

        @inspected_by_batch[batch.id] += 1
        @scanned_target_count += 1
        last_position_by_batch[batch.id.to_s] = target[:position]

        decision = @admission.decide(target)
        if decision.admit?
          @admission.record_admit(decision)
          return target
        end

        @admission.record_skip(decision)
      end
    end

    def batch_scan_exhausted?(batch)
      return true if batch.scan_budget_exhausted?
      return false if @scan_policy.nil?

      @inspected_by_batch[batch.id] >= @scan_policy.max_targets_per_batch
    end

    def record_scan_exhausted(batch)
      return if @scan_exhausted_recorded[batch.id]

      @scan_exhausted_recorded[batch.id] = true
      @scan_budget_exhausted_count += 1
    end

    def result_for(entries, last_owner_key: @cursor.last_owner_key, last_batch_by_owner: @cursor.last_batch_by_owner, last_position_by_batch: @cursor.last_position_by_batch)
      Result.new(
        planned: entries,
        next_cursor: FollowImport::FairnessCursor::State.new(
          last_owner_key: last_owner_key,
          last_batch_by_owner: last_batch_by_owner,
          last_position_by_batch: last_position_by_batch,
          source: @cursor.source
        ),
        admission_stats: collected_stats
      )
    end

    def collected_stats
      @admission.stats.merge(
        'scanned_target_count' => @scanned_target_count,
        'windows_scanned' => @windows_scanned,
        'scan_budget_exhausted_count' => @scan_budget_exhausted_count
      )
    end
  end
end
