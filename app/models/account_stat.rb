# frozen_string_literal: true
# == Schema Information
#
# Table name: account_stats
#
#  id                   :bigint(8)        not null, primary key
#  account_id           :bigint(8)        not null
#  statuses_count       :bigint(8)        default(0), not null
#  following_count      :bigint(8)        default(0), not null
#  followers_count      :bigint(8)        default(0), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  last_status_at       :datetime
#  subscribing_count    :bigint(8)        default(0), not null
#  outbox_next_page_url :string
#

class AccountStat < ApplicationRecord
  self.locking_column = nil
  self.ignored_columns = %w(lock_version)

  belongs_to :account, inverse_of: :account_stat

  update_index('accounts', :account)

  after_commit :request_group_directory_index, on: [:create, :update, :destroy]

  private

  def request_group_directory_index
    return unless GroupDirectory::Indexing.live_sync_enabled?
    return unless account&.group?
    # A new row often has a null last_status_at, and Rails does not record
    # that default as a change. The group still has to enter the index.
    return unless destroyed? || previously_new_record? || previous_changes.key?('last_status_at')

    GroupDirectory::Indexing.enqueue(account_id)
  end
end
