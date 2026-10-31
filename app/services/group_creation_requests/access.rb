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

    def reviewer?(_request, _account)
      false
    end
  end
end
