# frozen_string_literal: true

class AccountPolicy < ApplicationPolicy
  def index?
    role.can?(:manage_users)
  end

  def show?
    role.can?(:manage_users)
  end

  def warn?
    moderate_account?
  end

  def suspend?
    moderate_account? && !record.instance_actor?
  end

  def destroy?
    record.suspended_temporarily? && role.can?(:delete_user_data)
  end

  def unsuspend?
    role.can?(:manage_users) && record.suspension_origin_local?
  end

  def sensitive?
    moderate_account?
  end

  def unsensitive?
    role.can?(:manage_users)
  end

  def silence?
    moderate_account?
  end

  def unsilence?
    role.can?(:manage_users)
  end

  def redownload?
    role.can?(:manage_federation)
  end

  def remove_avatar?
    moderate_account?
  end

  def remove_header?
    moderate_account?
  end

  def subscribe?
    role.can?(:manage_federation)
  end

  def unsubscribe?
    role.can?(:manage_federation)
  end

  def change_default_priority?
    role.can?(:manage_users) && !record.default_priority?
  end

  def change_high_priority?
    role.can?(:manage_users) && !record.high_priority?
  end

  def change_low_priority?
    role.can?(:manage_users) && !record.low_priority?
  end

  def change_person_type?
    role.can?(:manage_users) && !record.person_type?
  end

  def change_service_type?
    role.can?(:manage_users) && !record.service_type?
  end

  def change_group_type?
    role.can?(:manage_users) && !record.group_type?
  end

  def review?
    role.can?(:manage_taxonomies)
  end

  def memorialize?
    role.can?(:delete_user_data) && role.overrides?(record.role) && !record.instance_actor?
  end

  private

  def moderate_account?
    role.can?(:manage_users, :manage_reports) && role.overrides?(record.role)
  end
end
