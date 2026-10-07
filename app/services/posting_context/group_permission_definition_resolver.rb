# frozen_string_literal: true

class PostingContext::GroupPermissionDefinitionResolver
  # Independent of the affiliation collection snapshot. Same duration,
  # separate timestamp.
  FRESH_FOR = 1.day

  def call(group_account)
    return unavailable_result unless group_account&.group?

    fetched_at = group_account.permission_definitions_fetched_at
    status = snapshot_status(fetched_at)
    fresh = status == 'fresh'

    {
      snapshot_status: status,
      fetched_at: fetched_at&.utc&.iso8601,
      can_create: fresh ? group_account.can_create_affiliation : nil,
      can_view: fresh ? group_account.can_view_affiliation : nil,
    }
  end

  private

  def snapshot_status(fetched_at)
    return 'unfetched' if fetched_at.blank?
    return 'fresh' if fetched_at > FRESH_FOR.ago

    'stale'
  end

  def unavailable_result
    {
      snapshot_status: 'unavailable',
      fetched_at: nil,
      can_create: nil,
      can_view: nil,
    }
  end
end
