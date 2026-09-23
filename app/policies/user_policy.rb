# frozen_string_literal: true

class UserPolicy < ApplicationPolicy
  def reset_password?
    access_user?
  end

  def change_email?
    access_user?
  end

  def disable_2fa?
    access_user?
  end

  def disable_sign_in_token_auth?
    access_user?
  end

  def enable_sign_in_token_auth?
    access_user?
  end

  def confirm?
    role.can?(:manage_user_access) && !record.confirmed?
  end

  # Permission-only check for the already-confirmed resend redirect.
  # confirm? is false once the user is confirmed, so it cannot guard that path.
  def resend?
    role.can?(:manage_user_access)
  end

  def enable?
    role.can?(:manage_users)
  end

  def approve?
    role.can?(:manage_users) && !record.approved?
  end

  def reject?
    role.can?(:manage_users) && !record.approved?
  end

  def disable?
    role.can?(:manage_users) && role.overrides?(record.user_role)
  end

  # Legacy promote/demote only accepts targets whose booleans and role_id
  # still match the Owner / Moderator / Everyone bridge. Admin and custom
  # roles are left untouched. Promotion also refuses a resulting role that
  # outranks the actor; an equal role is not elevation.
  def promote?
    return false unless role.can?(:manage_roles)
    return false unless record.approved? && legacy_promotable_tier?

    next_role = legacy_promotion_role
    return false if next_role.nil? || next_role.overrides?(role)

    role.overrides?(record.user_role)
  end

  def demote?
    return false unless role.can?(:manage_roles)
    return false unless legacy_bridge_tier == :moderator

    role.overrides?(record.user_role)
  end

  private

  def access_user?
    role.can?(:manage_user_access) && role.overrides?(record.user_role)
  end

  def legacy_promotable_tier?
    %i(everyone moderator).include?(legacy_bridge_tier)
  end

  # Everyone -> Moderator, Moderator -> Owner. Anything else is not a legacy step.
  def legacy_promotion_role
    case legacy_bridge_tier
    when :everyone
      legacy_named_role('Moderator')
    when :moderator
      legacy_named_role('Owner')
    end
  end

  def legacy_bridge_tier
    return @legacy_bridge_tier if defined?(@legacy_bridge_tier)
    return @legacy_bridge_tier = nil unless record.respond_to?(:role_id)

    owner_id = legacy_named_role('Owner')&.id
    moderator_id = legacy_named_role('Moderator')&.id

    @legacy_bridge_tier = if record.admin? && owner_id && record.role_id == owner_id
                            :owner
                          elsif !record.admin? && record.moderator? && moderator_id && record.role_id == moderator_id
                            :moderator
                          elsif !record.admin? && !record.moderator? && legacy_everyone_role?
                            :everyone
                          end
  end

  def legacy_everyone_role?
    # role_id nil is the effective Everyone role. -99 is UserRole.everyone.
    record.role_id.nil? || record.role_id == -99
  end

  def legacy_named_role(name)
    @legacy_named_roles ||= {}
    @legacy_named_roles[name] ||= UserRole.find_by(name: name)
  end
end
