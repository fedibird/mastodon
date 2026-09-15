# frozen_string_literal: true

# Shadow dispatch plan. Entries are a point-in-time simulation of which
# currently-pending targets the account-first allocator would select.
# They are not reservations and do not mutate rows.
#
# planned_count / planned_owner_count / planned_batch_count describe
# the selected simulation. executable_owner_count / executable_batch_count
# describe the eligible candidate population after Eligibility and
# missing-owner filtering — not the number of owners/batches that
# received a plan slot. claimed_count stays 0 while shadow-only.
# When planning was not attempted, these counts are nil, not 0.
module FollowImport
  class DispatchPlan
    attr_reader :observed_at, :global_pending_count, :active_batch_count, :execution_config,
                :entries, :skipped_missing_owner_count, :fairness_state_source, :shadow_plan_budget,
                :effective_shadow_plan_budget, :local_load

    def self.observe(observed_at:, global_pending_count:, active_batch_count:, execution_config:, planning: {})
      new(
        observed_at: observed_at,
        global_pending_count: global_pending_count,
        active_batch_count: active_batch_count,
        execution_config: execution_config,
        planning: planning
      )
    end

    def initialize(observed_at:, global_pending_count:, active_batch_count:, execution_config:, planning: {})
      planning = planning.to_h.symbolize_keys
      @observed_at = observed_at
      @global_pending_count = global_pending_count
      @active_batch_count = active_batch_count
      @execution_config = execution_config
      @planned = planning.fetch(:planned, false)
      @entries = planning[:entries] || []
      @skipped_missing_owner_count = planning[:skipped_missing_owner_count]
      @fairness_state_source = planning[:fairness_state_source]
      @shadow_plan_budget = planning[:shadow_plan_budget]
      @executable_owner_count = planning[:executable_owner_count]
      @executable_batch_count = planning[:executable_batch_count]
      @effective_shadow_plan_budget = planning[:effective_shadow_plan_budget]
      @local_load = planning[:local_load]
      @local_load_fallback_used = planning[:local_load_fallback_used]
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

      @executable_owner_count
    end

    def executable_batch_count
      return unless @planned

      @executable_batch_count
    end

    def planned_owner_count
      return unless @planned

      @entries.map(&:owner_key).uniq.size
    end

    def planned_batch_count
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

    def local_load_state
      return unless @planned

      @local_load&.state
    end

    def local_load_budget_percent
      return unless @planned

      @local_load&.budget_percent
    end

    def local_load_recommended_budget
      return unless @planned

      @local_load&.recommended_budget
    end

    def local_load_would_skip
      return unless @planned

      @local_load&.would_skip
    end

    def local_load_measurement_complete
      return unless @planned

      @local_load&.measurement_complete
    end

    def local_load_profile_version
      return unless @planned

      @local_load&.profile_version
    end

    def local_load_profile_source
      return unless @planned

      @local_load&.profile_source
    end

    def local_load_reasons
      return [] unless @planned

      Array(@local_load&.reasons)
    end

    def local_load_fallback_used
      return unless @planned

      @local_load_fallback_used
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
