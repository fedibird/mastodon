# frozen_string_literal: true

class InvitePolicy < ApplicationPolicy
  def index?
    role.can?(:manage_invites)
  end

  def create?
    role.can?(:invite_users) && un_silenced?
  end

  def deactivate_all?
    role.can?(:manage_invites)
  end

  def destroy?
    owner? || role.can?(:manage_invites)
  end

  private

  def owner?
    record.user_id == current_user&.id
  end

  def un_silenced?
    !current_user&.account&.silenced?
  end
end
