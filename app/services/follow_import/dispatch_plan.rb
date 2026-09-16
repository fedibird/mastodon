# frozen_string_literal: true

# Dispatch plan for one global scheduler tick.
#
# Entries are a point-in-time selection of currently-pending targets.
# They are not reservations and do not mutate rows by themselves.
#
# Shadow mode (GLOBAL=false, SHADOW=true): claimed_count is always 0.
# Global mode: claimed_count is the number of successful enqueues
# attached via +execution+ after the plan was built.
#
# planned_count / planned_owner_count / planned_batch_count describe
# the selected plan. executable_owner_count / executable_batch_count
# describe the eligible candidate population after Eligibility and
# missing-owner filtering. When planning was not attempted, these
# counts are nil, not 0.
module FollowImport
  class DispatchPlan
    attr_reader :observed_at, :global_pending_count, :active_batch_count, :execution_config,
                :entries, :skipped_missing_owner_count, :fairness_state_source, :shadow_plan_budget,
                :effective_shadow_plan_budget, :local_load, :scheduler_mode, :global_base_budget,
                :effective_global_budget

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
      @scheduler_mode = (planning[:scheduler_mode] || 'shadow').to_s
      @global_base_budget = planning[:global_base_budget]
      @effective_global_budget = planning[:effective_global_budget]
      @claimed_count = planning[:claimed_count]
      @skipped_stale_count = planning[:skipped_stale_count]
      @skipped_unrecoverable_count = planning[:skipped_unrecoverable_count]
      @skipped_wrong_owner_count = planning[:skipped_wrong_owner_count]
      @remote_admission_enabled = planning[:remote_admission_enabled]
      @remote_admission_configured = planning[:remote_admission_configured]
      @remote_profile_version = planning[:remote_profile_version]
      @skipped_destination_cap_count = planning[:skipped_destination_cap_count]
      @skipped_origin_cap_count = planning[:skipped_origin_cap_count]
      @skipped_unavailable_count = planning[:skipped_unavailable_count]
      @skipped_retry_after_count = planning[:skipped_retry_after_count]
      @skipped_recent_429_count = planning[:skipped_recent_429_count]
      @scanned_target_count = planning[:scanned_target_count]
      @windows_scanned = planning[:windows_scanned]
      @scan_budget_exhausted_count = planning[:scan_budget_exhausted_count]
      @mapped_origin_candidate_count = planning[:mapped_origin_candidate_count]
      @adaptive_remote_shadow_enabled = planning[:adaptive_remote_shadow_enabled]
      @adaptive_remote_configured = planning[:adaptive_remote_configured]
      @adaptive_profile_version = planning[:adaptive_profile_version]
      @adaptive_shadow_evaluated_current_claim_count = planning[:adaptive_shadow_evaluated_current_claim_count]
      @adaptive_shadow_would_block_current_claim_count = planning[:adaptive_shadow_would_block_current_claim_count]
      @adaptive_shadow_destination_would_block_count = planning[:adaptive_shadow_destination_would_block_count]
      @adaptive_shadow_origin_would_block_count = planning[:adaptive_shadow_origin_would_block_count]
      @adaptive_runtime_unavailable_count = planning[:adaptive_runtime_unavailable_count]
      @adaptive_destination_cap_min = planning[:adaptive_destination_cap_min]
      @adaptive_destination_cap_max = planning[:adaptive_destination_cap_max]
      @adaptive_origin_cap_min = planning[:adaptive_origin_cap_min]
      @adaptive_origin_cap_max = planning[:adaptive_origin_cap_max]
      @adaptive_destination_state_sources = planning[:adaptive_destination_state_sources]
      @adaptive_origin_state_sources = planning[:adaptive_origin_state_sources]
    end

    def planned?
      @planned
    end

    def shadow?
      @scheduler_mode != 'global'
    end

    def planned_count
      return unless @planned

      @entries.size
    end

    def claimed_count
      return 0 if shadow?
      return unless @planned

      @claimed_count
    end

    def with_execution(execution)
      return self if execution.nil?

      @claimed_count = execution.claimed_count
      @skipped_stale_count = execution.skipped_stale_count
      @skipped_unrecoverable_count = execution.skipped_unrecoverable_count
      @skipped_wrong_owner_count = execution.skipped_wrong_owner_count
      self
    end

    def skipped_stale_count
      return unless @planned

      @skipped_stale_count
    end

    def skipped_unrecoverable_count
      return unless @planned

      @skipped_unrecoverable_count
    end

    def skipped_wrong_owner_count
      return unless @planned

      @skipped_wrong_owner_count
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

    def remote_admission_enabled
      return unless @planned

      @remote_admission_enabled
    end

    def remote_admission_configured
      return unless @planned

      @remote_admission_configured
    end

    def remote_profile_version
      return unless @planned

      @remote_profile_version
    end

    def skipped_destination_cap_count
      return unless @planned

      @skipped_destination_cap_count
    end

    def skipped_origin_cap_count
      return unless @planned

      @skipped_origin_cap_count
    end

    def skipped_unavailable_count
      return unless @planned

      @skipped_unavailable_count
    end

    def skipped_retry_after_count
      return unless @planned

      @skipped_retry_after_count
    end

    def skipped_recent_429_count
      return unless @planned

      @skipped_recent_429_count
    end

    def scanned_target_count
      return unless @planned

      @scanned_target_count
    end

    def windows_scanned
      return unless @planned

      @windows_scanned
    end

    def scan_budget_exhausted_count
      return unless @planned

      @scan_budget_exhausted_count
    end

    def mapped_origin_candidate_count
      return unless @planned

      @mapped_origin_candidate_count
    end

    def adaptive_remote_shadow_enabled
      return unless @planned

      @adaptive_remote_shadow_enabled
    end

    def adaptive_remote_configured
      return unless @planned

      @adaptive_remote_configured
    end

    def adaptive_profile_version
      return unless @planned

      @adaptive_profile_version
    end

    def adaptive_shadow_evaluated_current_claim_count
      return unless @planned

      @adaptive_shadow_evaluated_current_claim_count
    end

    def adaptive_shadow_would_block_current_claim_count
      return unless @planned

      @adaptive_shadow_would_block_current_claim_count
    end

    def adaptive_shadow_destination_would_block_count
      return unless @planned

      @adaptive_shadow_destination_would_block_count
    end

    def adaptive_shadow_origin_would_block_count
      return unless @planned

      @adaptive_shadow_origin_would_block_count
    end

    def adaptive_runtime_unavailable_count
      return unless @planned

      @adaptive_runtime_unavailable_count
    end

    def adaptive_destination_cap_min
      return unless @planned

      @adaptive_destination_cap_min
    end

    def adaptive_destination_cap_max
      return unless @planned

      @adaptive_destination_cap_max
    end

    def adaptive_origin_cap_min
      return unless @planned

      @adaptive_origin_cap_min
    end

    def adaptive_origin_cap_max
      return unless @planned

      @adaptive_origin_cap_max
    end

    def adaptive_destination_state_sources
      return unless @planned

      @adaptive_destination_state_sources
    end

    def adaptive_origin_state_sources
      return unless @planned

      @adaptive_origin_state_sources
    end
  end
end
