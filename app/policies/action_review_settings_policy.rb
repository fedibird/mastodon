# frozen_string_literal: true

class ActionReviewSettingsPolicy < ApplicationPolicy
  def show?
    admin?
  end

  def update?
    admin?
  end
end
