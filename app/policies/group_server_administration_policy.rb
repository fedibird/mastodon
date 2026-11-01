# frozen_string_literal: true

# Server administrators only. Moderator, a normal user, and a group owner
# or group moderator do not pass. The HTTP policy and the domain services
# both call GroupManagement.server_administrator?.
class GroupServerAdministrationPolicy < ApplicationPolicy
  def index?
    allowed?
  end

  def show?
    allowed?
  end

  def update?
    allowed?
  end

  def approve?
    allowed?
  end

  def reject?
    allowed?
  end

  def icon?
    allowed?
  end

  def retry_icon?
    allowed?
  end

  private

  def allowed?
    GroupManagement.server_administrator?(current_account)
  end
end
