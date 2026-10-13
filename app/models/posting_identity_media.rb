# frozen_string_literal: true

# == Schema Information
#
# Table name: posting_identity_media
#
#  id                  :bigint(8)        not null, primary key
#  grantee_user_id     :bigint(8)        not null
#  delegation_id       :bigint(8)        not null
#  posting_account_id  :bigint(8)        not null
#  media_attachment_id :bigint(8)        not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
class PostingIdentityMedia < ApplicationRecord
  # The table name stays singular. media_attachment_id is an identifier,
  # not a foreign key, so destroying the attachment leaves this row.
  self.table_name = 'posting_identity_media'

  belongs_to :grantee_user, class_name: 'User'
  belongs_to :delegation, class_name: 'PostingIdentityDelegation'
  belongs_to :posting_account, class_name: 'Account'
  belongs_to :media_attachment, optional: true

  validates :media_attachment_id, presence: true, uniqueness: true
end
