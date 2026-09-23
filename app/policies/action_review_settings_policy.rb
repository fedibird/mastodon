# frozen_string_literal: true

class ActionReviewSettingsPolicy < ApplicationPolicy
  def show?
    role.can?(:manage_settings)
  end

  def update?
    role.can?(:manage_settings)
  end
end
