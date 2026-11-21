# frozen_string_literal: true

# == Schema Information
#
# Table name: post_drafts
#
#  id             :bigint(8)        not null, primary key
#  account_id     :bigint(8)        not null
#  client_uuid    :string(36)       not null
#  schema_version :integer          not null
#  revision       :integer          default(1), not null
#  payload        :jsonb            not null
#  state          :string(16)       default("active"), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
# Unpublished composer snapshot owned by the signed-in account.
# sender id inside the payload is a posting target, not the owner.
# Rows never create a Status, ScheduledStatus, notification, or delivery.
class PostDraft < ApplicationRecord
  SCHEMA_VERSION = 1
  LIMIT = 100
  STATES = %w(active).freeze

  belongs_to :account
  has_many :post_draft_media_attachments, -> { order(:position) }, dependent: :delete_all, inverse_of: :post_draft
  has_many :media_attachments, through: :post_draft_media_attachments

  validates :client_uuid, :schema_version, :revision, :state, :payload, presence: true
  validates :state, inclusion: { in: STATES }
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates :schema_version, inclusion: { in: [SCHEMA_VERSION] }
end
