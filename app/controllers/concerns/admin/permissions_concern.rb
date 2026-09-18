# frozen_string_literal: true

module Admin::PermissionsConcern
  extend ActiveSupport::Concern

  included do
    before_action :require_moderator_or_admin_permissions
  end

  private

  def require_moderator_or_admin_permissions
    forbidden unless current_user&.functional? && current_user&.staff?
  end
end
