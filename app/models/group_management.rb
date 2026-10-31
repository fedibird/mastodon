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

  # Server administration is the Owner permission bit or the Admin role's
  # manage_settings permission. Moderator and the legacy users.admin flag
  # are not enough. Action Review policy modes never satisfy this check.
  def server_administrator?(account)
    return false unless local_functional_person?(account)

    user = account.user
    user.can?(:administrator) || user.can?(:manage_settings)
  end
end
