# frozen_string_literal: true

class CanonicalEmailBlockPolicy < ApplicationPolicy
  def index?
    admin?
  end

  def show?
    admin?
  end

  def test?
    admin?
  end

  def create?
    admin?
  end

  def destroy?
    admin?
  end
end
