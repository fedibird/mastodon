# frozen_string_literal: true

class ApplicationPolicy
  attr_reader :current_account, :record

  def initialize(current_account, record)
    @current_account = current_account
    @record          = record
  end

  def admin?
    current_user&.functional? && current_user&.admin?
  end

  def moderator?
    current_user&.functional? && current_user&.moderator?
  end

  def staff?
    current_user&.functional? && current_user&.staff?
  end

  private

  def current_user
    current_account&.user
  end

  def user_signed_in?
    !current_user.nil?
  end
end
