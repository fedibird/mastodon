# frozen_string_literal: true

module GroupCreationRequestsHelper
  def group_creation_request_acct(username)
    name = username.to_s
    return if name.blank?

    "@#{name}@#{Rails.configuration.x.local_domain}"
  end

  def group_creation_request_state(request)
    t("group_creation_requests.states.#{request.state}")
  end
end
