# frozen_string_literal: true

# == Schema Information
#
# Table name: follow_import_dispatch_observations
#
#  id               :bigint(8)        not null, primary key
#  batch_id         :bigint(8)
#  observed_at      :datetime         not null
#  candidate_count       :integer          default(0), not null
#  claimed_count         :integer          default(0), not null
#  pending_count         :integer
#  load_snapshot         :jsonb
#  execution_policy      :jsonb            not null
#  created_at            :datetime         not null
#  batch_pending_before  :integer
#  batch_pending_after   :integer
#  global_pending_count  :integer
#  active_batch_count    :integer
#
# One observation per FollowImport::BatchExecutionWorker pass. load_snapshot is
# captured BEFORE any claim/enqueue. Count columns are nullable: 0 means an
# observed empty set, NULL means the measurement was unavailable. Observation
# only — never consulted to pause, slow, or skip dispatch.
class FollowImportDispatchObservation < ApplicationRecord
  self.table_name = 'follow_import_dispatch_observations'
  self.record_timestamps = false

  belongs_to :batch, class_name: 'FollowImportBatch', optional: true
end
