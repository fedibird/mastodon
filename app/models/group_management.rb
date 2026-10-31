# frozen_string_literal: true

# Shared eligibility checks for local group administration records.
# Remote management is intentionally rejected here so a later phase can
# allow it without a database migration. Account#user is a login, not a
# group owner; callers must not treat the two as the same relationship.
module GroupManagement
  module_function

  def local_functional_person?(account)
    return false unless account&.local?
    return false unless account.person_type?
    return false if account.instance_actor?

    account.user&.functional? == true
  end

  # Parent issue #657 separates server administrators from group moderators
  # and from the server Moderator role. Owner has can?(:administrator).
  # The Admin role does not have that bit, but it has manage_settings,
  # which is the server-settings gate and not granted to Moderator.
  # The legacy users.admin flag does not select a role, so it is not enough.
  # Action Review policy modes never satisfy this check.
  def server_administrator?(account)
    return false unless local_functional_person?(account)

    user = account.user
    user.can?(:administrator) || user.can?(:manage_settings)
  end
end
