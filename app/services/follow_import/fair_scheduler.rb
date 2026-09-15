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
# Pure algorithm: given synthetic owners/batches/targets and a cursor,
# returns a deterministic plan. No Sidekiq, Redis, or ActiveRecord.
#
# Optional destination_cap is for specs / future destination-share math.
# Runtime PR B leaves it unset (no remote admission).
module FollowImport
  class FairScheduler
    ALGORITHM      = 'account_first_rr'
    SCHEMA_VERSION = 2

    Entry = Struct.new(:owner_key, :batch_id, :target_id, :position, :destination_domain, keyword_init: true)
    Result = Struct.new(:planned, :next_cursor, keyword_init: true)

    class Batch
      attr_reader :id

      def initialize(id, feed)
        @id = id
        @feed = feed
      end

      def take
        @feed.shift
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
      def initialize(rows)
        @rows = rows.dup
      end

      def shift
        @rows.shift
      end

      def remaining?
        @rows.any?
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

    def initialize(budget:, owners:, cursor: FollowImport::FairnessCursor::State.empty, destination_cap: nil)
      @budget = budget.to_i
      @owners = owners
      @cursor = cursor
      @destination_cap = destination_cap
    end

    def plan
      entries = []
      return result_for(entries) if @budget <= 0

      dest_counts = Hash.new(0)
      last_owner = @cursor.last_owner_key
      last_batch_by_owner = @cursor.last_batch_by_owner.dup
      last_position_by_batch = @cursor.last_position_by_batch.dup
      owners = prepared_owners

      while entries.size < @budget
        progressed = false

        owners.each do |owner|
          break if entries.size >= @budget

          batch, target = take_from_owner(owner, dest_counts)
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
          last_position_by_batch[batch.id.to_s] = target[:position]
          domain = target[:destination_domain]
          dest_counts[domain] += 1 if domain
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

    def take_from_owner(owner, dest_counts)
      selected_batch = nil
      selected_target = nil

      owner.each_candidate_batch do |batch|
        target = take_admissible(batch, dest_counts)
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

    def take_admissible(batch, dest_counts)
      loop do
        target = batch.take
        return if target.nil?
        return target unless capped_destination?(target, dest_counts)
      end
    end

    def capped_destination?(target, dest_counts)
      return false if @destination_cap.nil?

      domain = target[:destination_domain]
      domain.present? && dest_counts[domain] >= @destination_cap
    end

    def result_for(entries, last_owner_key: @cursor.last_owner_key, last_batch_by_owner: @cursor.last_batch_by_owner, last_position_by_batch: @cursor.last_position_by_batch)
      Result.new(
        planned: entries,
        next_cursor: FollowImport::FairnessCursor::State.new(
          last_owner_key: last_owner_key,
          last_batch_by_owner: last_batch_by_owner,
          last_position_by_batch: last_position_by_batch,
          source: @cursor.source
        )
      )
    end
  end
end
