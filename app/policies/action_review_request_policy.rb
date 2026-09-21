# frozen_string_literal: true

class ActionReviewRequestPolicy < ApplicationPolicy
  def index?
    staff?
  end

  def show?
    staff?
  end
end
