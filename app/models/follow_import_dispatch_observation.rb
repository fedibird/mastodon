# frozen_string_literal: true

# == Schema Information
#
# Table name: follow_import_dispatch_observations
#
#  id               :bigint(8)        not null, primary key
#  batch_id         :bigint(8)
#  observed_at      :datetime         not null
#  candidate_count       :integer
#  claimed_count         :integer
#  pending_count         :integer
#  load_snapshot         :jsonb
#  execution_policy      :jsonb            not null
#  created_at            :datetime         not null
#  batch_pending_before  :integer
#  batch_pending_after   :integer
#  global_pending_count  :integer
#  active_batch_count    :integer
#  pass_error_class      :string
#  local_load_enforcement_enabled :boolean
#  local_load_state      :string
#  local_load_budget_percent :integer
#  local_load_recommended_budget :integer
#  effective_execution_budget :integer
#  local_load_would_skip :boolean
#  local_load_measurement_complete :boolean
#  local_load_profile_version :integer
#  local_load_profile_source :string
#  local_load_fallback_used :boolean
#  load_deferred         :boolean
#  local_load_decision   :jsonb
#
# One observation per FollowImport::BatchExecutionWorker pass. load_snapshot is
# captured BEFORE any claim/enqueue. Count columns are nullable: 0 means an
# observed empty set, NULL means the measurement was unavailable.
# claimed_count is incremented after each successful enqueue so a later raise
# still reports partial progress. pass_error_class is set when the pass
# raised (telemetry only — the error is still re-raised).
# Local-load columns are NULL when enforcement was not evaluated.
# Observation only — never consulted to pause, slow, or skip dispatch.
class FollowImportDispatchObservation < ApplicationRecord
  self.table_name = 'follow_import_dispatch_observations'
  self.record_timestamps = false

  belongs_to :batch, class_name: 'FollowImportBatch', optional: true
end
