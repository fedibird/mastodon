# frozen_string_literal: true
# == Schema Information
#
# Table name: imports
#
#  id                :bigint(8)        not null, primary key
#  type              :integer          not null
#  approved          :boolean          default(FALSE), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  data_file_name    :string
#  data_content_type :string
#  data_file_size    :bigint(8)
#  data_updated_at   :datetime
#  account_id                       :bigint(8)        not null
#  overwrite                        :boolean          default(FALSE), not null
#  follow_import_pipeline_version   :integer
#

class Import < ApplicationRecord
  FILE_TYPES = %w(text/plain text/csv application/csv).freeze
  MODES = %i(merge overwrite).freeze

  # Integer pipeline version. Recovery and worker execution are version-strict:
  # only CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION is supported by this revision.
  # NULL is leftover / provenance-unknown and must never be auto-recovered.
  # An unknown non-NULL version (e.g. a future 2) is also not executed here;
  # leftover cleanup still deletes NULL only and must not touch unknown versions.
  CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION = 1

  self.inheritance_column = false

  belongs_to :account

  enum type: [:following, :account_subscribings, :blocking, :muting, :domain_blocking, :bookmarks]

  # Recovery-aware: this revision's supported Follow Import pipeline version.
  # The marker is execution intent, not "executor ownership" — it is persisted
  # before ProcessImportWorker is enqueued, and is never stamped onto an
  # existing unmarked row by the watchdog or worker.
  scope :follow_import_recovery_aware, lambda {
    following.where(follow_import_pipeline_version: CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION)
  }
  scope :without_follow_import_batch, lambda {
    where.not(id: FollowImportBatch.where.not(import_id: nil).select(:import_id))
  }
  scope :legacy_follow_imports_before, lambda { |before_time|
    following
      .where(follow_import_pipeline_version: nil)
      .where('imports.created_at < ?', before_time)
      .without_follow_import_batch
  }

  validates :type, presence: true
  validates_with ImportValidator, on: :create

  has_attached_file :data
  validates_attachment_content_type :data, content_type: FILE_TYPES
  validates_attachment_presence :data

  def mode
    overwrite? ? :overwrite : :merge
  end

  def mode=(str)
    self.overwrite = str.to_sym == :overwrite
  end

  def follow_import_recovery_aware?
    following? && follow_import_pipeline_version == CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION
  end

  # Assigns the current pipeline version on a new follow Import. Call this
  # before the row is saved (or persist it before enqueue). Never use this to
  # "upgrade" a leftover unmarked Import — those stay NULL.
  def assign_follow_import_pipeline_version
    return unless following?
    return if follow_import_pipeline_version.present?

    self.follow_import_pipeline_version = CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION
  end

  def persist_follow_import_pipeline_version!
    assign_follow_import_pipeline_version
    save! if will_save_change_to_follow_import_pipeline_version?
  end
end
