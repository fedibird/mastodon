# frozen_string_literal: true

module Reboost
  # Announce and Undo for one actor and one original status share this key.
  module AnnounceLock
    module_function

    def key(account_id, status_id)
      "announce:#{account_id}:status:#{status_id}"
    end
  end
end
