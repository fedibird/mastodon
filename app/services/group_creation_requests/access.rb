# frozen_string_literal: true

module GroupCreationRequests
  # Preview of a staged icon. P2 can allow a server administrator by changing
  # reviewer? without putting the file on a public URL.
  module Access
    module_function

    def preview_allowed?(request, account)
      return false if request.nil? || account.nil?
      return false unless request.icon_previewable?

      owner?(request, account) || reviewer?(request, account)
    end

    def owner?(request, account)
      request.requester_account_id == account.id
    end

    # Server administrators may be shown a staged icon by a later review
    # screen. This does not add that screen. The settings controller still
    # loads only the signed-in account's own requests.
    def reviewer?(_request, account)
      GroupManagement.server_administrator?(account)
    end
  end
end
