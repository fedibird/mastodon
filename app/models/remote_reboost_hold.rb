# frozen_string_literal: true

class RemoteReboostHold < ApplicationRecord
  belongs_to :account
  belongs_to :reblog_of, class_name: 'Status'

  def self.store!(account_id, reblog_of_id, uri, published_at, payload, available_at, delivery_options: {}) # rubocop:disable Metrics/ParameterLists
    row = find_or_initialize_by(account_id: account_id, reblog_of_id: reblog_of_id)
    if row.new_record?
      row.assign_attributes(
        activity_uri: uri,
        published_at: published_at,
        available_at: available_at,
        payload: payload,
        delivery_options: delivery_options
      )
      row.save!
      row.schedule_apply!
      return row
    end

    if uri == row.activity_uri
      row.update!(delivery_options: merge_delivery_options(row.delivery_options, delivery_options))
      row.schedule_apply! if row.apply_enqueued_at.nil?
      return row
    end
    return row if published_at.nil? || (row.published_at && published_at <= row.published_at)

    row.update!(activity_uri: uri, published_at: published_at, payload: payload, delivery_options: merge_delivery_options(row.delivery_options, delivery_options))
    row.schedule_apply! if row.apply_enqueued_at.nil?
    row
  end

  # A raised perform_at leaves apply_enqueued_at nil, so the same Announce
  # or the scheduler can enqueue it again. A job recorded before available_at
  # is enqueued once more after it is due, then the new timestamp stops the scan.
  def schedule_apply!
    Reboost::RemoteApplyWorker.perform_at(available_at, id)
    update!(apply_enqueued_at: Time.current)
  end

  def self.merge_delivery_options(current, incoming)
    current = current.is_a?(Hash) ? current.stringify_keys : {}
    incoming = incoming.is_a?(Hash) ? incoming.stringify_keys : {}
    merged = current.merge(incoming)
    merged['delivery'] = true if current['delivery'] == true || incoming['delivery'] == true
    merged['override_timestamps'] = true if current['override_timestamps'] == true || incoming['override_timestamps'] == true
    merged
  end

  def self.schedule_outstanding!(now = Time.current)
    where('apply_enqueued_at IS NULL OR (available_at <= ? AND apply_enqueued_at < available_at)', now).limit(100).each(&:schedule_apply!)
  end
end
