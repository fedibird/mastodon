# frozen_string_literal: true

# == Schema Information
#
# Table name: posting_identity_posts
#
#  id                 :bigint(8)        not null, primary key
#  grantee_user_id    :bigint(8)        not null
#  delegation_id      :bigint(8)        not null
#  posting_account_id :bigint(8)        not null
#  status_id          :bigint(8)        not null
#  posted_at          :datetime         not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
class PostingIdentityPost < ApplicationRecord
  belongs_to :grantee_user, class_name: 'User'
  belongs_to :delegation, class_name: 'PostingIdentityDelegation'
  belongs_to :posting_account, class_name: 'Account'
  belongs_to :status

  validates :posted_at, presence: true
end
