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
# claimed_count is always 0 while the scheduler is shadow-only (PR A).
# Count columns are nullable: 0 means an observed empty set, NULL means
# the measurement was unavailable. Observation only — never consulted to
# pause, slow, or skip dispatch. Does not store handles, payloads, inbox
# paths, target accts, or moderation scores.
class FollowImportDispatchTickObservation < ApplicationRecord
  self.table_name = 'follow_import_dispatch_tick_observations'
  self.record_timestamps = false
end
