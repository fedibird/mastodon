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
    role.can?(:manage_users) && role.overrides?(record.role)
  end

  # Whether the actor may change this user's current role. The destination
  # role is checked separately so it cannot outrank the actor.
  def change_role?
    role.can?(:manage_roles) && role.overrides?(record.role)
  end

  private

  def access_user?
    role.can?(:manage_user_access) && role.overrides?(record.role)
  end
end
