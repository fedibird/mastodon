# == Schema Information
#
# Table name: account_subscribes
#
#  id                :bigint(8)        not null, primary key
#  account_id        :bigint(8)
#  target_account_id :bigint(8)
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  list_id           :bigint(8)
#

class AccountSubscribe < ApplicationRecord
  belongs_to :account
  belongs_to :target_account, class_name: 'Account'
  belongs_to :list, optional: true

  validates :account_id, uniqueness: { scope: [:target_account_id, :list_id] }

  scope :recent, -> { reorder(id: :desc) }
  scope :subscribed_lists, ->(account) { AccountSubscribe.where(target_account_id: account.id).where.not(list_id: nil).select(:list_id).uniq }

end
