# frozen_string_literal: true

# == Schema Information
#
# Table name: follow_import_dispatch_observations
#
#  id               :bigint(8)        not null, primary key
#  batch_id         :bigint(8)
#  observed_at      :datetime         not null
#  candidate_count  :integer          default(0), not null
#  claimed_count    :integer          default(0), not null
#  pending_count    :integer          default(0), not null
#  load_snapshot    :jsonb            not null
#  execution_policy :jsonb            not null
#  created_at       :datetime         not null
#
# One observation per FollowImport::BatchExecutionWorker pass: how many targets
# were visible/claimed, plus a Sidekiq load snapshot and the execution-policy
# knobs in force at that moment. Observation only — never consulted to pause,
# slow, or skip dispatch.
class FollowImportDispatchObservation < ApplicationRecord
  self.table_name = 'follow_import_dispatch_observations'
  self.record_timestamps = false

  belongs_to :batch, class_name: 'FollowImportBatch', optional: true
end
