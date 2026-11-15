# frozen_string_literal: true

class RemoteReboostHold < ApplicationRecord
  belongs_to :account
  belongs_to :reblog_of, class_name: 'Status'

  def self.store!(account_id, reblog_of_id, uri, published_at, payload, available_at)
    row = find_or_initialize_by(account_id: account_id, reblog_of_id: reblog_of_id)
    if row.new_record?
      row.activity_uri = uri
      row.published_at = published_at
      row.available_at = available_at
      row.payload = payload
      row.save!
      Reboost::RemoteApplyWorker.perform_at(row.available_at, row.id)
      return row
    end

    return row if uri == row.activity_uri
    return row if published_at.nil? || (row.published_at && published_at <= row.published_at)

    row.update!(activity_uri: uri, published_at: published_at, payload: payload)
    row
  end
end
