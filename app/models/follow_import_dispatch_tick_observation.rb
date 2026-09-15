# frozen_string_literal: true

# == Schema Information
#
# Table name: follow_import_dispatch_tick_observations
#
#  id                    :bigint(8)        not null, primary key
#  observed_at           :datetime         not null
#  tick_id               :string           not null
#  scheduler_mode        :string           not null
#  lease_acquired        :boolean          not null
#  outcome               :string           not null
#  global_pending_count  :integer
#  active_batch_count    :integer
#  claimed_count         :integer          default(0), not null
#  planned_count         :integer
#  planned_owner_count   :integer
#  planned_batch_count   :integer
#  executable_owner_count :integer
#  executable_batch_count :integer
#  unique_destination_count :integer
#  skipped_missing_owner_count :integer
#  fairness_state_source :string
#  local_load_state      :string
#  local_load_budget_percent :integer
#  local_load_recommended_budget :integer
#  effective_shadow_plan_budget :integer
#  local_load_would_skip :boolean
#  local_load_measurement_complete :boolean
#  local_load_profile_version :integer
#  local_load_profile_source :string
#  load_snapshot         :jsonb
#  execution_config      :jsonb
#  error_class           :string
#  metadata              :jsonb            not null
#  created_at            :datetime         not null
#
# One observation per global Follow Import dispatch-scheduler tick.
# Dedicated from follow_import_dispatch_observations (per-batch worker
# passes) so "this BatchExecutionWorker pass claimed N" is not confused
# with "the global shadow tick claimed 0".
#
# claimed_count is always 0 while the scheduler is shadow-only.
# planned_count is the account-first simulation size when a plan was
# built; NULL when planning was not attempted. executable_* is the
# eligible candidate population; planned_owner/batch_count is who
# received a slot. Other new aggregates follow the same 0-vs-NULL
# rule. Observation only — never consulted to
# pause, slow, or skip dispatch. Does not store handles, payloads, inbox
# paths, target accts, owner keys, or moderation scores.
class FollowImportDispatchTickObservation < ApplicationRecord
  self.table_name = 'follow_import_dispatch_tick_observations'
  self.record_timestamps = false
end
