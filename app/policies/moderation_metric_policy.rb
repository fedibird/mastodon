# frozen_string_literal: true

class ModerationMetricPolicy < ApplicationPolicy
  def show?
    staff?
  end
end
