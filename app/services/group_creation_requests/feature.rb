# frozen_string_literal: true

module GroupCreationRequests
  # Off until P2 can approve a request end to end. Unset uses the default
  # false in config/settings.yml. This is not on the admin settings form.
  module Feature
    module_function

    def enabled?
      ActiveModel::Type::Boolean.new.cast(Setting.group_creation_requests)
    end
  end
end
