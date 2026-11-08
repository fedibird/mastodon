# frozen_string_literal: true

# == Schema Information
#
# Table name: emoji_mute_revisions
#
#  id         :bigint(8)        not null, primary key
#  account_id :bigint(8)        not null
#  revision   :bigint(8)        default(0), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

class EmojiMuteRevision < ApplicationRecord
  belongs_to :account

  def self.with_lock_for(account_id)
    transaction do
      yield lock_row(account_id)
    end
  end

  def self.lock_row(account_id)
    row = find_by(account_id: account_id)
    if row
      row.lock!
      row
    else
      create_locked(account_id)
    end
  end

  def self.create_locked(account_id)
    row = create!(account_id: account_id, revision: 0)
    row.lock!
    row
  rescue ActiveRecord::RecordNotUnique
    row = find_by!(account_id: account_id)
    row.lock!
    row
  end

  def bump!
    self.revision += 1
    save!
    revision
  end
end
