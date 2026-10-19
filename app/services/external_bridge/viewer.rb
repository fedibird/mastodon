# frozen_string_literal: true

module ExternalBridge
  # Request-local user id. Nil in jobs and account-only callers, which
  # therefore cannot read a projection.
  class Viewer < ActiveSupport::CurrentAttributes
    attribute :user_id
  end
end
