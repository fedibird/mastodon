# frozen_string_literal: true

# Shadow dispatch plan. Entries are a point-in-time simulation of which
# currently-pending targets the account-first allocator would select.
# They are not reservations and do not mutate rows.
#
# planned_count is the size of this simulation. claimed_count stays 0
# while the scheduler is shadow-only. When planning was not attempted,
# planned_count is nil (unavailable), not 0.
module FollowImport
  class DispatchPlan
    attr_reader :observed_at, :global_pending_count, :active_batch_count, :execution_config,
                :entries, :skipped_missing_owner_count, :fairness_state_source, :shadow_plan_budget

    def self.observe(observed_at:, global_pending_count:, active_batch_count:, execution_config:,
                     planned: false, entries: [], skipped_missing_owner_count: nil, fairness_state_source: nil,
                     shadow_plan_budget: nil)
      new(
        observed_at: observed_at,
        global_pending_count: global_pending_count,
        active_batch_count: active_batch_count,
        execution_config: execution_config,
        planned: planned,
        entries: entries,
        skipped_missing_owner_count: skipped_missing_owner_count,
        fairness_state_source: fairness_state_source,
        shadow_plan_budget: shadow_plan_budget
      )
    end

    def initialize(observed_at:, global_pending_count:, active_batch_count:, execution_config:,
                   planned: false, entries: [], skipped_missing_owner_count: nil, fairness_state_source: nil,
                   shadow_plan_budget: nil)
      @observed_at = observed_at
      @global_pending_count = global_pending_count
      @active_batch_count = active_batch_count
      @execution_config = execution_config
      @planned = planned
      @entries = entries
      @skipped_missing_owner_count = skipped_missing_owner_count
      @fairness_state_source = fairness_state_source
      @shadow_plan_budget = shadow_plan_budget
    end

    def planned?
      @planned
    end

    def planned_count
      return unless @planned

      @entries.size
    end

    def claimed_count
      0
    end

    def executable_owner_count
      return unless @planned

      @entries.map(&:owner_key).uniq.size
    end

    def executable_batch_count
      return unless @planned

      @entries.map(&:batch_id).uniq.size
    end

    def unique_destination_count
      return unless @planned

      @entries.map(&:destination_domain).compact.uniq.size
    end

    def planned_counts_by_owner
      return {} unless @planned

      @entries.each_with_object(Hash.new(0)) { |entry, memo| memo[entry.owner_key] += 1 }
    end

    def planned_counts_by_destination
      return {} unless @planned

      @entries.each_with_object(Hash.new(0)) do |entry, memo|
        next if entry.destination_domain.blank?

        memo[entry.destination_domain] += 1
      end
    end
  end
end
