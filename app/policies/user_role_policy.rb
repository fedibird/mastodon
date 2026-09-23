# frozen_string_literal: true

class UserRolePolicy < ApplicationPolicy
  def index?
    role.can?(:manage_roles)
  end

  def create?
    role.can?(:manage_roles)
  end

  def update?
    role.can?(:manage_roles) && (role.overrides?(record) || role.id == record.id)
  end

  # Temporary until the legacy boolean bridge stops resolving Owner, Admin,
  # and Moderator by name. Those roles, and Everyone, cannot be deleted.
  # Custom roles return to the upstream destroy rule above.
  def destroy?
    return false if record.everyone?
    return false if UserRole::LEGACY_BRIDGE_ROLE_NAMES.include?(record.name)

    role.can?(:manage_roles) && role.overrides?(record) && role.id != record.id
  end
end
