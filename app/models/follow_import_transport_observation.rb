# frozen_string_literal: true

# == Schema Information
#
# Table name: follow_import_transport_observations
#
#  id                  :bigint(8)        not null, primary key
#  batch_id            :bigint(8)
#  target_id           :bigint(8)
#  phase               :string           not null
#  destination_domain  :string
#  endpoint_origin     :string
#  sidekiq_queue       :string
#  sidekiq_job_id      :string
#  started_at          :datetime         not null
#  finished_at         :datetime         not null
#  duration_ms         :integer          not null
#  outcome             :string           not null
#  http_status         :integer
#  retry_after_seconds :integer
#  error_class         :string
#  metadata            :jsonb            not null
#  created_at          :datetime         not null
#
# Technical observation of one Follow Import transport attempt (account
# resolution or ActivityPub delivery). Not a moderation ledger row: it stores
# domain/endpoint/timing/status facts only. batch_id and target_id are optional
# correlation tokens without foreign keys.
class FollowImportTransportObservation < ApplicationRecord
  self.table_name = 'follow_import_transport_observations'
  self.record_timestamps = false

  PHASES = %w(resolve_account activitypub_delivery).freeze

  belongs_to :batch, class_name: 'FollowImportBatch', optional: true
  belongs_to :target, class_name: 'FollowImportTarget', optional: true
end
