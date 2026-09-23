# frozen_string_literal: true

# The legacy staff gate used to reject every admin request before Pundit ran.
# Custom roles are allowed or refused by each action's policy instead.
module Admin::PermissionsConcern
  extend ActiveSupport::Concern
end
