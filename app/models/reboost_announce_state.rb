# frozen_string_literal: true

class ReboostAnnounceState < ApplicationRecord
  belongs_to :account
  belongs_to :reblog_of, class_name: 'Status', optional: true

  CURRENT = 'current'
  SUPERSEDED = 'superseded'

  def self.superseded?(account_id, uri)
    return false if uri.blank?

    exists?(account_id: account_id, uri: uri, state: SUPERSEDED)
  end

  def self.current_for(account_id, reblog_of_id)
    find_by(account_id: account_id, reblog_of_id: reblog_of_id, state: CURRENT)
  end

  def self.remember_current!(account_id, reblog_of_id, uri, published_at)
    return if uri.blank?

    transaction do
      where(account_id: account_id, reblog_of_id: reblog_of_id, state: CURRENT).where.not(uri: uri).update_all(state: SUPERSEDED, updated_at: Time.current)
      row = find_or_initialize_by(account_id: account_id, uri: uri)
      row.reblog_of_id = reblog_of_id
      row.published_at = published_at
      row.state = CURRENT
      row.save!
    end
  end

  def self.supersede!(account_id, uri, reblog_of_id: nil)
    return if uri.blank?

    row = find_or_initialize_by(account_id: account_id, uri: uri)
    row.state = SUPERSEDED
    row.reblog_of_id ||= reblog_of_id
    row.save!
  end
end
