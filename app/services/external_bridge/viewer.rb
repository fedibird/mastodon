# frozen_string_literal: true

module ExternalBridge
  # Request-local user id. Nil in jobs and account-only callers, which
  # therefore cannot read a projection.
  class Viewer < ActiveSupport::CurrentAttributes
    attribute :user_id

    def self.with_user(user_id)
      previous = self.user_id
      self.user_id = user_id
      yield
    ensure
      self.user_id = previous
    end
  end
end
