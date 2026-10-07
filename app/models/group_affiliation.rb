# frozen_string_literal: true

# A relationship a remote Group published in its affiliations collection.
# Rows are positive evidence only. A missing or stale row is unknown, not a denial.
class GroupAffiliation < ApplicationRecord
  # Keep the composite unique index inside PostgreSQL's btree row limit.
  SUBJECT_URI_MAX_LENGTH = 1_024
  RELATIONSHIP_MAX_LENGTH = 1_024
  AFFILIATION_URI_MAX_LENGTH = 2_048

  belongs_to :group_account, class_name: 'Account', inverse_of: :group_affiliations

  validates :subject_uri, presence: true, length: { maximum: SUBJECT_URI_MAX_LENGTH }
  validates :relationship, presence: true, length: { maximum: RELATIONSHIP_MAX_LENGTH }
  validates :affiliation_uri, length: { maximum: AFFILIATION_URI_MAX_LENGTH }, allow_blank: true
end
