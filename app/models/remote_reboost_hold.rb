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
        delivery_options: normalize_delivery_options(delivery_options)
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

    row.update!(activity_uri: uri, published_at: published_at, payload: payload, delivery_options: normalize_delivery_options(delivery_options))
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

  # Same Announce id only. A later fetch cannot downgrade a delivery or drop
  # an inbox that already received this id. A different id stores its own options.
  def self.merge_delivery_options(current, incoming)
    current = stringify_options(current)
    incoming = stringify_options(incoming)
    merged = current.merge(incoming)
    merged['delivery'] = true if current['delivery'] == true || incoming['delivery'] == true
    merged['override_timestamps'] = true if current['override_timestamps'] == true || incoming['override_timestamps'] == true
    merged['delivered_to_account_ids'] = recipient_ids(current, incoming)
    merged.delete('delivered_to_account_id')
    merged['relayed_through_account_id'] = incoming['relayed_through_account_id'].presence || current['relayed_through_account_id']
    merged
  end

  def self.normalize_delivery_options(incoming)
    incoming = stringify_options(incoming)
    incoming['delivered_to_account_ids'] = recipient_ids(incoming)
    incoming.delete('delivered_to_account_id')
    incoming
  end

  def self.recipient_ids(*hashes)
    hashes.flat_map { |hash| Array(hash['delivered_to_account_ids']) + Array(hash['delivered_to_account_id']) }.compact.uniq
  end

  def self.stringify_options(options)
    options.is_a?(Hash) ? options.stringify_keys : {}
  end

  def self.schedule_outstanding!(now = Time.current)
    where('apply_enqueued_at IS NULL OR (available_at <= ? AND apply_enqueued_at < available_at)', now).limit(100).each(&:schedule_apply!)
  end
end
