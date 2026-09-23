# frozen_string_literal: true

class ActionReviewRequestPolicy < ApplicationPolicy
  def index?
    role.can?(:manage_reports)
  end

  def show?
    role.can?(:manage_reports)
  end

  def approve?
    role.can?(:manage_reports)
  end

  def reject?
    role.can?(:manage_reports)
  end
end
