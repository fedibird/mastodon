# frozen_string_literal: true

# Read-only console view of one status. Missing Redis data stays
# unknown. A stored group Announce is evidence of redistribution, not
# of the current community page. HTTP 2xx is not remote acceptance.
#
# Nested Announce objects that wrap a Create activity are not rewritten
# by this reader. If the existing Announce receiver did not store a
# reblog of the local status, the result stays unobserved.
class PostingContext::GroupPostObservationReader
  def call(status)
    group = status.audience_account
    record = record_for(status, group)

    {
      'status_id' => status.id.to_s,
      'target_account_id' => group&.id&.to_s,
      'adapter' => record&.fetch('adapter', nil),
      'local_status' => status.local? ? 'created' : 'not_local',
      'delivery_queue' => queue_state(record),
      'transport' => transport(record),
      'group_announce' => announce(status, group),
      'remote_acceptance' => 'unknown',
      'community_listing' => 'not_verified',
    }
  end

  private

  def record_for(status, group)
    return if group.nil?

    PostingContext::GroupFederationObservation.read(status.id, group.id)
  end

  def queue_state(record)
    return 'unknown' if record.nil?
    return 'observed' if record['queue_observed'] == true

    'not_queued'
  end

  def transport(record)
    if record.nil?
      return {
        'last_outcome' => nil,
        'http_status' => nil,
        'http_2xx_observed' => nil,
        'attempt_count' => nil,
        'terminal_failure' => nil,
      }
    end

    {
      'last_outcome' => record['last_attempt_outcome'],
      'http_status' => presence(record['last_http_status']),
      'http_2xx_observed' => record['http_2xx_observed'] == true,
      'attempt_count' => record['attempt_count'].to_i,
      'terminal_failure' => record['terminal_failure'] == true,
    }
  end

  def announce(status, group)
    return { 'observed' => false, 'evidence' => 'not_applicable' } unless announce_checkable?(status, group)

    found = Status.where(account_id: group.id, reblog_of_id: status.id).where.not(uri: [nil, '']).exists?
    if found
      { 'observed' => true, 'evidence' => 'stored_reblog' }
    else
      { 'observed' => false, 'evidence' => 'none' }
    end
  end

  def announce_checkable?(status, group)
    status.local? &&
      group.present? &&
      status.audience_account_id == group.id &&
      !group.local? &&
      group.group? &&
      group.uri.present?
  end

  def presence(value)
    return if value.nil? || value == ''

    value
  end
end
