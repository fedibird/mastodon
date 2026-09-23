# frozen_string_literal: true

class SubscriptionPolicy < ApplicationPolicy
  def index?
    role.can?(:manage_federation)
  end
end
