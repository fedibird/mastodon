# frozen_string_literal: true

class ModerationMetricPolicy < ApplicationPolicy
  def show?
    role.can?(:manage_reports)
  end
end
