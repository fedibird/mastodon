# frozen_string_literal: true

class ApplicationPolicy
  attr_reader :current_account, :record

  def initialize(current_account, record)
    @current_account = current_account
    @record          = record
  end

  private

  def current_user
    current_account&.user
  end

  # Permissions are ignored unless the user can actually act. A disabled,
  # unconfirmed, unapproved, suspended, memorial, or moved user is nobody.
  def role
    return UserRole.nobody unless current_user&.functional?

    current_user.role
  end

  def user_signed_in?
    !current_user.nil?
  end
end
